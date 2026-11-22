import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

import 'db.dart';
import 'jobs.dart';
import 'library.dart';
import 'log.dart';
import 'paths.dart';

/// Covers picked by hand: saved in the covers folder as custom-<hash>.jpg.
class CustomCovers {
  /// Saves a picture (any common format) as a cover and returns its key, or
  /// null if it isn't a picture.
  static Future<String?> save(Uint8List bytes) async {
    final im = img.decodeImage(bytes);
    if (im == null) return null;
    // Big enough for the largest cover on screen, small enough to sync quickly.
    final small = im.height > 900 ? img.copyResize(im, height: 900, interpolation: img.Interpolation.average) : im;
    final jpg = Uint8List.fromList(img.encodeJpg(small, quality: 88));
    final key = 'custom-${sha1.convert(jpg).toString().substring(0, 20)}';
    await writeFileSafely(Covers.I.fileForFp(key), jpg);
    return key;
  }

  /// A picture from the web (an image address that was copied).
  static Future<String?> fromUrl(String url) async {
    final u = Uri.tryParse(url.trim());
    if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) return null;
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await c.getUrl(u);
      req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 Sable');
      final res = await req.close();
      if (res.statusCode != 200) return null;
      final b = BytesBuilder(copy: false);
      await for (final chunk in res) {
        b.add(chunk);
      }
      return await save(b.takeBytes());
    } catch (_) {
      return null;
    } finally {
      c.close(force: true);
    }
  }
}

/// Finds book descriptions online: Google Books first, then Open Library.
/// Nothing is sent but the title and author.
class Lookup {
  static const _ua = 'Sable book reader (personal library)';

  static Future<Map<String, dynamic>?> _getJson(String url) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await c.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, _ua);
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode == 429) throw const HttpException('Too many requests');
      if (res.statusCode != 200) return null;
      final body = await utf8.decoder.bind(res).join();
      return (jsonDecode(body) as Map).cast<String, dynamic>();
    } finally {
      c.close(force: true);
    }
  }

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  /// Do the found title and the book's title look like the same book?
  static bool sameTitle(String found, String wanted) {
    final a = _norm(found), b = _norm(wanted);
    if (a.isEmpty || b.isEmpty) return false;
    return a == b || a.contains(b) || b.contains(a);
  }

  /// Plain text from the HTML some descriptions come as.
  static String clean(String s) {
    var t = s
        .replaceAll(RegExp(r'<\s*br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>\s*<p[^>]*>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    t = t
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ');
    return t.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// Picks a description out of a Google Books answer.
  static String? fromGoogle(Map<String, dynamic> j, String title) {
    for (final it in (j['items'] as List? ?? const [])) {
      final vi = (it as Map)['volumeInfo'] as Map? ?? const {};
      final t = '${vi['title'] ?? ''} ${vi['subtitle'] ?? ''}';
      final d = vi['description'] as String?;
      if (d != null && d.trim().length > 40 && sameTitle(t, title)) return clean(d);
    }
    return null;
  }

  static String? fromOpenLibraryWork(Map<String, dynamic> j) {
    final d = j['description'];
    final s = d is String ? d : (d is Map ? d['value'] as String? : null);
    if (s == null || s.trim().length < 40) return null;
    // Open Library sometimes adds a source list after a line of dashes.
    return clean(s.split(RegExp(r'\n-{3,}')).first);
  }

  static Future<String?> description(String title, String? author) async {
    final t = title.trim();
    if (t.isEmpty) return null;
    final a = (author ?? '').split(RegExp(r'[,&;]')).first.trim();
    final q = 'intitle:${Uri.encodeQueryComponent(t)}${a.isEmpty ? '' : '+inauthor:${Uri.encodeQueryComponent(a)}'}';
    try {
      final g = await _getJson('https://www.googleapis.com/books/v1/volumes?q=$q&maxResults=8&printType=books');
      final d = g == null ? null : fromGoogle(g, t);
      if (d != null) return d;
    } catch (e) {
      if ('$e'.contains('Too many')) rethrow;
    }
    try {
      final s = await _getJson('https://openlibrary.org/search.json?title=${Uri.encodeQueryComponent(t)}'
          '${a.isEmpty ? '' : '&author=${Uri.encodeQueryComponent(a)}'}&limit=3&fields=key,title');
      for (final doc in (s?['docs'] as List? ?? const [])) {
        final m = doc as Map;
        if (!sameTitle('${m['title'] ?? ''}', t)) continue;
        final w = await _getJson('https://openlibrary.org${m['key']}.json');
        final d = w == null ? null : fromOpenLibraryWork(w);
        if (d != null) return d;
      }
    } catch (_) {}
    return null;
  }

  static const jobName = 'Finding descriptions';

  /// Looks up descriptions for these books and series (those without one),
  /// as a job with its progress.
  static void run({List<Volume> volumes = const [], List<SeriesEntry> series = const [], bool onlyMissing = true}) {
    final vs = [for (final v in volumes) if (!onlyMissing || v.primary.shownDescription == null) v];
    final ss = [
      for (final s in series)
        if (!onlyMissing || Library.I.infoFor(s.key).shownDescription == null) s,
    ];
    if (vs.isEmpty && ss.isEmpty) return;
    Jobs.I.add(Job(jobName, (job) async {
      final total = vs.length + ss.length;
      var done = 0, found = 0;
      job.progress(0, total: total, detail: 'books');
      Future<void> pause() => Future<void>.delayed(const Duration(milliseconds: 350));
      for (final s in ss) {
        if (!await job.checkpoint()) break;
        final first = s.volumes.first.primary;
        var d = await description(s.label, first.displayAuthor);
        // No description for the series itself: the first book's will do.
        d ??= first.shownDescription;
        if (d != null) {
          final info = Library.I.infoFor(s.key)..foundDescription = d;
          Db.I.saveSeriesInfo(info);
          found++;
        }
        job.progress(++done, detail: s.label);
        await pause();
      }
      for (final v in vs) {
        if (!await job.checkpoint()) break;
        final b = v.primary;
        final d = await description(b.displayTitle, b.displayAuthor);
        if (d != null) {
          for (final f in v.files) {
            f.foundDescription = d;
            Db.I.updateExtras(f);
          }
          found++;
        }
        job.progress(++done, detail: b.displayTitle);
        await pause();
      }
      AppLog.I.info('Descriptions: found $found of $total');
      Library.I.changed();
      return 'Found $found description${found == 1 ? '' : 's'} of $total';
    }));
  }
}
