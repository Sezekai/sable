import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'db.dart';
import 'jobs.dart';
import 'library.dart';
import 'log.dart';
import 'paths.dart';
import 'settings.dart';
import 'sync_protocol.dart';
import 'sync_server.dart' show syncPort, discoveryPort, discoveryAsk;

/// A PC found on the home network.
class FoundPc {
  FoundPc(this.name, this.host, this.port, this.id);
  final String name, host, id;
  final int port;
}

class SyncError implements Exception {
  SyncError(this.message, {this.unpaired = false});
  final String message;
  final bool unpaired;
  @override
  String toString() => message;
}

/// The phone side of sync. Keeps a copy of the library and all reading
/// records from the PC, and sends back what was read and changed here.
class SyncClient extends ChangeNotifier {
  SyncClient._();
  static final SyncClient I = SyncClient._();

  // Pairing, kept in sync.json in the phone's data folder.
  String host = '';
  int port = syncPort;
  String pcName = '';
  String pcId = '';
  String token = '';
  String deviceName = 'Phone';
  int lastSyncAt = 0;
  String lastResult = '';
  bool lastFailed = false;

  /// Can the PC be reached right now?
  bool online = false;
  bool syncing = false;
  Timer? _timer;

  bool get paired => token.isNotEmpty && host.isNotEmpty;
  String get _file => p.join(AppPaths.I.data, 'sync.json');
  String get base => 'http://$host:$port';

  static const syncName = 'Syncing with the PC';

  void load() {
    try {
      final f = File(_file);
      if (!f.existsSync()) return;
      final m = jsonDecode(f.readAsStringSync()) as Map;
      host = m['host'] as String? ?? '';
      port = m['port'] as int? ?? syncPort;
      pcName = m['pcName'] as String? ?? '';
      pcId = m['pcId'] as String? ?? '';
      token = m['token'] as String? ?? '';
      deviceName = m['deviceName'] as String? ?? deviceName;
      lastSyncAt = m['lastSyncAt'] as int? ?? 0;
      lastResult = m['lastResult'] as String? ?? '';
    } catch (_) {}
  }

  void _save() {
    try {
      writeStringSafelySync(
          _file,
          const JsonEncoder.withIndent('  ').convert({
            'host': host,
            'port': port,
            'pcName': pcName,
            'pcId': pcId,
            'token': token,
            'deviceName': deviceName,
            'lastSyncAt': lastSyncAt,
            'lastResult': lastResult,
          }));
    } catch (_) {}
    notifyListeners();
  }

  /// Syncs every few minutes while the app is open (quietly, only when the PC can be reached).
  void startAuto() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => sync(quiet: true));
  }

  HttpClient _client({Duration timeout = const Duration(seconds: 6)}) => HttpClient()
    ..connectionTimeout = timeout
    ..idleTimeout = const Duration(seconds: 10);

  Future<(int, List<int>)> _request(String method, String path,
      {Object? body, Duration timeout = const Duration(seconds: 6), String? toHost, int? toPort}) async {
    final c = _client(timeout: timeout);
    try {
      final req = await c.openUrl(method, Uri.parse('http://${toHost ?? host}:${toPort ?? port}$path'));
      req.headers.set('x-sable-token', token);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close();
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in res) {
        bytes.add(chunk);
      }
      return (res.statusCode, bytes.takeBytes() as List<int>);
    } finally {
      c.close(force: true);
    }
  }

  Map<String, dynamic> _decode(List<int> b) => (jsonDecode(utf8.decode(b)) as Map).cast<String, dynamic>();

  String _errorOf(int status, List<int> body) {
    try {
      return _decode(body)['error'] as String? ?? 'The PC answered $status';
    } catch (_) {
      return 'The PC answered $status';
    }
  }

  /// Looks for Sable on PCs on the home network.
  Future<List<FoundPc>> discover({Duration wait = const Duration(seconds: 2)}) async {
    final found = <String, FoundPc>{};
    RawDatagramSocket? s;
    try {
      s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      s.broadcastEnabled = true;
      s.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final dg = s?.receive();
        if (dg == null) return;
        try {
          final m = jsonDecode(utf8.decode(dg.data)) as Map;
          if (m['sable'] != true) return;
          found[m['id'] as String? ?? dg.address.address] =
              FoundPc(m['name'] as String? ?? 'PC', dg.address.address, m['port'] as int? ?? syncPort, m['id'] as String? ?? '');
        } catch (_) {}
      });
      final ask = utf8.encode(discoveryAsk);
      for (var i = 0; i < 3; i++) {
        s.send(ask, InternetAddress('255.255.255.255'), discoveryPort);
        // Also this device itself (for tests on one computer).
        s.send(ask, InternetAddress.loopbackIPv4, discoveryPort);
        await Future<void>.delayed(wait ~/ 3);
      }
    } catch (e) {
      AppLog.I.warn('Looking for the PC: $e');
    } finally {
      s?.close();
    }
    return found.values.toList();
  }

  /// Pairs with the PC at [h] using the code shown on the PC.
  Future<void> pair(String h, int pt, String code, {String? device}) async {
    final (st, body) = await _request('POST', '/pair',
        body: {'code': code.trim(), 'device': device ?? deviceName}, toHost: h.trim(), toPort: pt);
    if (st != 200) throw SyncError(_errorOf(st, body));
    final m = _decode(body);
    host = h.trim();
    port = pt;
    token = m['token'] as String;
    pcName = m['pc'] as String? ?? 'PC';
    pcId = m['pcId'] as String? ?? '';
    if (device != null) deviceName = device;
    lastResult = 'Paired with $pcName';
    _save();
    AppLog.I.info('Paired with $pcName ($host)');
  }

  void unpair() {
    token = '';
    online = false;
    lastResult = 'Not paired';
    _save();
  }

  /// Finds the PC again when its address changed (the router gave it a new one).
  Future<bool> _relocate() async {
    if (pcId.isEmpty) return false;
    for (final pc in await discover()) {
      if (pc.id == pcId) {
        host = pc.host;
        port = pc.port;
        _save();
        AppLog.I.info('Found $pcName at its new address $host');
        return true;
      }
    }
    return false;
  }

  Future<bool> _hello() async {
    try {
      final (st, body) = await _request('GET', '/api/hello', timeout: const Duration(seconds: 4));
      if (st == 401) throw SyncError(_errorOf(st, body), unpaired: true);
      return st == 200;
    } on SyncError {
      rethrow;
    } catch (_) {
      return false;
    }
  }

  /// Sends this phone's changes and brings in the PC's. With [quiet], an
  /// unreachable PC isn't reported as a problem (it's just away from home).
  Future<void> sync({bool quiet = false}) async {
    if (!paired || syncing) return;
    if (Jobs.I.isQueued(syncName)) return;
    // Not while a book is open: it syncs as soon as the book is closed.
    if (quiet && Library.I.books.any((b) => b.reading)) return;
    final done = Completer<void>();
    Jobs.I.add(Job(syncName, (job) async {
      try {
        return await _sync(job, quiet);
      } finally {
        if (!done.isCompleted) done.complete();
      }
    }));
    await done.future;
  }

  Future<String?> _sync(Job job, bool quiet) async {
    syncing = true;
    notifyListeners();
    try {
      job.progress(0, total: 4, detail: 'finding $pcName');
      var ok = await _hello();
      if (!ok && await _relocate()) ok = await _hello();
      online = ok;
      if (!ok) {
        if (!quiet) {
          lastFailed = true;
          lastResult = '$pcName can\'t be reached. Is it on, with Sable open, on the same WiFi?';
          _save();
        }
        return quiet ? 'PC not reachable' : lastResult;
      }

      // 1. Send this phone's changes.
      job.progress(1, detail: 'sending changes');
      final ops = Db.I.outbox();
      if (ops.isNotEmpty) {
        final (st, body) = await _request('POST', '/api/sync',
            body: {'device': deviceName, 'ops': ops}, timeout: const Duration(seconds: 20));
        if (st != 200) throw SyncError(_errorOf(st, body), unpaired: st == 401);
        Db.I.clearOutbox(ops.last['id'] as int);
      }

      // 2. Bring in everything from the PC.
      job.progress(2, detail: 'bringing in the library');
      final (st, body) = await _request('GET', '/api/snapshot', timeout: const Duration(seconds: 60));
      if (st != 200) throw SyncError(_errorOf(st, body), unpaired: st == 401);
      final snap = _decode(body);
      final fl = snap['folders'];
      if (fl is List) {
        Settings.I.folders = fl.whereType<Map>().map(LibFolder.fromJson).toList();
        Settings.I.save();
      }
      applySnapshot(Db.I, snap);
      // Changes made here while that was on its way are applied again on top.
      final pending = Db.I.outbox();
      if (pending.isNotEmpty) applyOps(Db.I, pending);
      Library.I.load();

      // 3. Covers for books that don't have one here yet.
      job.progress(3, detail: 'covers');
      final got = await _covers(job);

      lastSyncAt = nowSec();
      lastFailed = false;
      final n = Library.I.books.where(Library.I.visible).length;
      lastResult = 'Synced with $pcName · ${ops.length} change${ops.length == 1 ? '' : 's'} sent · $n books'
          '${got > 0 ? ' · $got new covers' : ''}';
      _save();
      return lastResult;
    } on SyncError catch (e) {
      lastFailed = true;
      lastResult = e.message;
      if (e.unpaired) unpair();
      _save();
      rethrow;
    } catch (e) {
      lastFailed = true;
      online = false;
      lastResult = 'Sync stopped part way: $e';
      _save();
      rethrow;
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// Fetches missing covers, 40 at a time.
  Future<int> _covers(Job job) async {
    final want = <String>{};
    for (final b in Library.I.books) {
      if (b.missing) continue;
      final k = Covers.I.keyFor(b);
      if (!File(Covers.I.fileForFp(k)).existsSync()) want.add(k);
    }
    // Series covers picked by hand.
    for (final i in Db.I.seriesInfo().values) {
      final k = i.cover;
      if (k != null && !File(Covers.I.fileForFp(k)).existsSync()) want.add(k);
    }
    if (want.isEmpty) return 0;
    Directory(AppPaths.I.thumbs).createSync(recursive: true);
    final list = want.toList();
    var got = 0;
    job.progress(0, total: list.length, detail: 'covers');
    for (var i = 0; i < list.length; i += 40) {
      if (!await job.checkpoint()) break;
      final batch = list.sublist(i, (i + 40).clamp(0, list.length));
      final (st, body) = await _request('POST', '/api/covers', body: {'fps': batch}, timeout: const Duration(seconds: 30));
      if (st != 200) break;
      final data = ByteData.sublistView(Uint8List.fromList(body));
      var o = 0;
      while (o + 6 <= data.lengthInBytes) {
        final fl = data.getUint16(o);
        o += 2;
        final fp = utf8.decode(body.sublist(o, o + fl));
        o += fl;
        final len = data.getUint32(o);
        o += 4;
        await writeFileSafely(Covers.I.fileForFp(fp), body.sublist(o, o + len));
        o += len;
        got++;
      }
      job.progress(i + batch.length, detail: 'covers');
      Covers.I.version++;
      Covers.I.changedNow();
    }
    return got;
  }

  /// Opens a download of a book file from the PC, from byte [from] on.
  Future<HttpClientResponse> openBook(String uid, {int from = 0, HttpClient? client}) async {
    final c = client ?? _client(timeout: const Duration(seconds: 8));
    final req = await c.getUrl(Uri.parse('$base/api/book/$uid'));
    req.headers.set('x-sable-token', token);
    if (from > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
    return req.close();
  }
}
