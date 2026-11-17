import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'db.dart';

import 'log.dart';
import 'paths.dart';
import 'sync_client.dart';

enum DlState { queued, running, waiting, failed }

/// One book being downloaded.
class DownloadItem {
  DownloadItem(this.uid, this.title, this.format, this.total);
  final String uid;
  final String title;
  final String format;
  int total;
  int received = 0;
  DlState state = DlState.queued;
  String? error;
  DateTime? started;
  int _startBytes = 0;

  double get fraction => total <= 0 ? 0 : (received / total).clamp(0, 1);
  Duration get elapsed => started == null ? Duration.zero : DateTime.now().difference(started!);

  /// Bytes per second since this download started (or resumed).
  double get speed {
    final s = elapsed.inMilliseconds / 1000;
    return s <= 0.5 ? 0 : (received - _startBytes) / s;
  }

  Duration? get timeLeft {
    final sp = speed;
    if (sp <= 0 || total <= 0) return null;
    return Duration(seconds: ((total - received) / sp).round());
  }
}

/// A book kept on the phone.
class Downloaded {
  Downloaded(this.uid, this.file, this.size, this.at, this.title);
  final String uid, file, title;
  final int size, at;
}

/// Books downloaded to the phone for reading away from the PC. Only books you
/// pick are downloaded (by book or by series) — never everything by itself.
class Downloads extends ChangeNotifier {
  Downloads._();
  static final Downloads I = Downloads._();

  final Map<String, Downloaded> done = {};
  final List<DownloadItem> queue = [];
  bool paused = false;
  DownloadItem? _current;
  HttpClient? _http;

  /// The whole batch: when it started and how much it was, for its overall progress.
  DateTime? batchStarted;
  int batchBytesDone = 0;

  String get dir => p.join(AppPaths.I.cache, 'downloads');

  void init() {
    Db.I.raw.execute('''CREATE TABLE IF NOT EXISTS downloads(
      book_uid TEXT PRIMARY KEY, file TEXT NOT NULL, size INTEGER NOT NULL, at INTEGER NOT NULL, title TEXT,
      format TEXT)''');
    Directory(dir).createSync(recursive: true);
    for (final r in Db.I.raw.select('SELECT * FROM downloads')) {
      final uid = r['book_uid'] as String;
      final at = r['at'] as int;
      final title = r['title'] as String? ?? '';
      if (at == 0) {
        // Still to do (the app was closed part way): carry on.
        queue.add(DownloadItem(uid, title, r['format'] as String? ?? 'epub', r['size'] as int));
      } else if (File(r['file'] as String).existsSync()) {
        done[uid] = Downloaded(uid, r['file'] as String, r['size'] as int, at, title);
      } else {
        Db.I.raw.execute('DELETE FROM downloads WHERE book_uid=?', [uid]);
      }
    }
    if (queue.isNotEmpty) Future(_pump);
  }

  bool isDone(Book b) => done.containsKey(b.uid);
  bool isQueued(Book b) => queue.any((q) => q.uid == b.uid);
  DownloadItem? itemFor(Book b) => queue.where((q) => q.uid == b.uid).firstOrNull;
  String? fileFor(Book b) => done[b.uid]?.file;

  int get usedBytes => done.values.fold(0, (a, d) => a + d.size);
  int get queuedBytes => queue.fold(0, (a, q) => a + (q.total - q.received));

  /// The overall progress of everything waiting (0…1), and a time-left estimate.
  double get batchFraction {
    final left = queuedBytes;
    final all = batchBytesDone + queue.fold<int>(0, (a, q) => a + q.received) + left;
    return all <= 0 ? 0 : 1 - left / all;
  }

  Duration get batchElapsed => batchStarted == null ? Duration.zero : DateTime.now().difference(batchStarted!);

  Duration? get batchTimeLeft {
    final s = batchElapsed.inMilliseconds / 1000;
    final got = batchBytesDone + queue.fold<int>(0, (a, q) => a + q.received - q._startBytes);
    if (s < 1 || got <= 0) return null;
    return Duration(seconds: (queuedBytes / (got / s)).round());
  }

  String _fileName(String uid, String format) => p.join(dir, '$uid.$format');

  /// Downloads these books (one file per book: the volume's preferred format).
  void add(Iterable<Book> books) {
    var n = 0;
    for (final b in books) {
      if (b.missing || done.containsKey(b.uid) || queue.any((q) => q.uid == b.uid)) continue;
      final it = DownloadItem(b.uid, b.cardTitle + (b.volumeText.isEmpty ? '' : ' · ${b.volumeText}'), b.format, b.size);
      queue.add(it);
      Db.I.raw.execute('INSERT OR REPLACE INTO downloads(book_uid,file,size,at,title,format) VALUES(?,?,?,0,?,?)',
          [b.uid, _fileName(b.uid, b.format), b.size, it.title, b.format]);
      n++;
    }
    if (n == 0) return;
    if (_current == null) {
      batchStarted = DateTime.now();
      batchBytesDone = 0;
    }
    notifyListeners();
    _pump();
  }

  /// Takes books off the phone (their copies on the PC are never touched).
  void remove(Iterable<Book> books) {
    for (final b in books) {
      cancel(b.uid);
      final d = done.remove(b.uid);
      if (d != null) {
        try {
          File(d.file).deleteSync();
        } catch (_) {}
      }
      Db.I.raw.execute('DELETE FROM downloads WHERE book_uid=?', [b.uid]);
    }
    notifyListeners();
  }

  /// Removes a download whose book is no longer in the library.
  void forget(String uid) {
    final d = done.remove(uid);
    if (d != null) {
      try {
        File(d.file).deleteSync();
      } catch (_) {}
    }
    Db.I.raw.execute('DELETE FROM downloads WHERE book_uid=?', [uid]);
    notifyListeners();
  }

  void removeAll() {
    for (final d in done.values.toList()) {
      try {
        File(d.file).deleteSync();
      } catch (_) {}
    }
    done.clear();
    Db.I.raw.execute('DELETE FROM downloads WHERE at > 0');
    notifyListeners();
  }

  void cancel(String uid) {
    final it = queue.where((q) => q.uid == uid).firstOrNull;
    if (it == null) return;
    queue.remove(it);
    if (_current == it) {
      _http?.close(force: true);
      _current = null;
    }
    try {
      File('${_fileName(uid, it.format)}.part').deleteSync();
    } catch (_) {}
    Db.I.raw.execute('DELETE FROM downloads WHERE book_uid=? AND at=0', [uid]);
    notifyListeners();
    _pump();
  }

  void cancelAll() {
    for (final q in queue.toList()) {
      cancel(q.uid);
    }
  }

  void setPaused(bool v) {
    paused = v;
    if (v) {
      _http?.close(force: true);
    } else {
      for (final q in queue) {
        if (q.state == DlState.waiting || q.state == DlState.failed) q.state = DlState.queued;
      }
      _pump();
    }
    notifyListeners();
  }

  /// Called after a successful sync: anything waiting for the PC carries on.
  void retryWaiting() {
    var any = false;
    for (final q in queue) {
      if (q.state == DlState.waiting) {
        q.state = DlState.queued;
        any = true;
      }
    }
    if (any) _pump();
  }

  Future<void> _pump() async {
    if (_current != null || paused) return;
    final next = queue.where((q) => q.state == DlState.queued).firstOrNull;
    if (next == null) {
      if (queue.isEmpty) batchStarted = null;
      notifyListeners();
      return;
    }
    _current = next;
    await _run(next);
    if (_current == next) _current = null;
    notifyListeners();
    unawaited(_pump());
  }

  Future<void> _run(DownloadItem it) async {
    final target = _fileName(it.uid, it.format);
    final part = File('$target.part');
    it.state = DlState.running;
    it.error = null;
    it.received = part.existsSync() ? part.lengthSync() : 0;
    it._startBytes = it.received;
    it.started = DateTime.now();
    notifyListeners();
    _http = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    IOSink? out;
    var lastNotify = DateTime.now();
    try {
      final res = await SyncClient.I.openBook(it.uid, from: it.received, client: _http);
      if (res.statusCode == 404 || res.statusCode == 401) {
        final msg = res.statusCode == 401 ? 'This phone isn\'t paired any more' : 'The PC doesn\'t have this book any more';
        await res.drain<void>();
        throw HttpException(msg);
      }
      if (res.statusCode != 200 && res.statusCode != 206) throw HttpException('The PC answered ${res.statusCode}');
      if (res.statusCode == 200) it.received = 0; // the PC sent it from the start
      final len = res.contentLength;
      if (len > 0) it.total = it.received + len;
      out = part.openWrite(mode: it.received > 0 ? FileMode.append : FileMode.write);
      await for (final chunk in res) {
        if (!queue.contains(it)) break; // cancelled
        out.add(chunk);
        it.received += chunk.length;
        if (DateTime.now().difference(lastNotify).inMilliseconds > 250) {
          lastNotify = DateTime.now();
          notifyListeners();
        }
      }
      await out.flush();
      await out.close();
      out = null;
      if (!queue.contains(it)) return;
      if (it.total > 0 && it.received < it.total) throw const HttpException('The connection dropped part way');
      final f = await part.rename(target);
      final size = await f.length();
      queue.remove(it);
      batchBytesDone += size - it._startBytes;
      final now = nowSec();
      done[it.uid] = Downloaded(it.uid, target, size, now, it.title);
      Db.I.raw.execute('UPDATE downloads SET at=?, size=?, file=? WHERE book_uid=?', [now, size, target, it.uid]);
      AppLog.I.info('Downloaded ${it.title} (${(size / 1048576).toStringAsFixed(1)} MB)');
    } catch (e) {
      await out?.close();
      if (!queue.contains(it)) return;
      if (paused) {
        it.state = DlState.queued;
      } else if (e is SocketException || e is HttpException && e.message.contains('dropped')) {
        // Away from the PC: waits, and carries on after the next sync.
        it.state = DlState.waiting;
        it.error = 'Waiting for the PC';
      } else {
        it.state = DlState.failed;
        it.error = '$e'.replaceFirst('HttpException: ', '');
        AppLog.I.warn('Download of ${it.title} failed: ${it.error}');
      }
    } finally {
      _http?.close(force: true);
      _http = null;
    }
  }

  /// A book that isn't downloaded, fetched from the PC just for reading now
  /// (kept in a temporary folder, not counted as a download).
  Future<String> fetchForReading(Book b, void Function(int got, int total) onProgress) async {
    final tmpDir = Directory(AppPaths.I.bookCache)..createSync(recursive: true);
    final target = File(p.join(tmpDir.path, '${b.uid}.${b.format}'));
    if (target.existsSync() && target.lengthSync() == b.size) return target.path;
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final res = await SyncClient.I.openBook(b.uid, client: c);
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw HttpException(res.statusCode == 404 ? 'The PC doesn\'t have this book any more' : 'The PC answered ${res.statusCode}');
      }
      final total = res.contentLength > 0 ? res.contentLength : b.size;
      final part = File('${target.path}.part');
      final out = part.openWrite();
      var got = 0;
      await for (final chunk in res) {
        out.add(chunk);
        got += chunk.length;
        onProgress(got, total);
      }
      await out.close();
      await part.rename(target.path);
      return target.path;
    } finally {
      c.close(force: true);
    }
  }
}
