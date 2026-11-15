import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import 'log.dart';

/// A tiny web server on this computer only (127.0.0.1), which the reader's
/// web view loads the book engine and the book from. Nothing outside this
/// computer can reach it.
class LocalServer {
  LocalServer._();
  static final LocalServer I = LocalServer._();

  HttpServer? _server;
  final String _secret = List.generate(16, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
  final Map<String, _Session> _sessions = {};

  int get port => _server?.port ?? 0;
  String get base => 'http://127.0.0.1:$port';

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle, onError: (e) => AppLog.I.warn('Reader server: $e'));
    AppLog.I.info('Reader server ready on port $port');
  }

  /// Registers a book for one reader. Returns the page URL to open.
  String open({
    required String bookPath,
    required Map<String, dynamic> Function() init,
    required void Function(Map<String, dynamic> event) onEvent,
  }) {
    final token = List.generate(12, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
    _sessions[token] = _Session(bookPath, init, onEvent);
    return '$base/$_secret/reader/index.html?t=$token';
  }

  void close(String url) {
    final t = Uri.parse(url).queryParameters['t'];
    if (t != null) _sessions.remove(t);
  }

  static const _types = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json',
    '.woff2': 'font/woff2',
    '.ttf': 'font/ttf',
    '.epub': 'application/epub+zip',
    '.mobi': 'application/x-mobipocket-ebook',
    '.azw3': 'application/vnd.amazon.ebook',
  };

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final seg = req.uri.pathSegments;
      if (seg.length < 2 || seg[0] != _secret) {
        res.statusCode = 404;
        await res.close();
        return;
      }
      res.headers.set('Cache-Control', 'no-store');
      final kind = seg[1];
      final rest = seg.skip(2).join('/');
      switch (kind) {
        case 'reader':
          if (rest.contains('..')) throw 'bad path';
          final data = await rootBundle.load('assets/reader/$rest');
          res.headers.set('Content-Type', _types[p.extension(rest)] ?? 'application/octet-stream');
          res.add(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        case 'fonts':
          final name = p.basename(rest);
          final asset = name.startsWith('Inter') ? 'assets/fonts/$name' : 'assets/reader/fonts/$name';
          final data = await rootBundle.load(asset);
          res.headers.set('Content-Type', _types[p.extension(name)] ?? 'application/octet-stream');
          res.add(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        case 'book':
          final s = _sessions[rest.split('/').first];
          if (s == null) throw 'no such book';
          final f = File(s.path);
          res.headers.set('Content-Type', _types[p.extension(s.path).toLowerCase()] ?? 'application/octet-stream');
          res.contentLength = await f.length();
          await res.addStream(f.openRead());
        case 'init':
          final s = _sessions[rest];
          if (s == null) throw 'no such book';
          res.headers.set('Content-Type', 'application/json');
          res.write(jsonEncode(s.init()));
        case 'event':
          final s = _sessions[rest];
          final body = await utf8.decoder.bind(req).join();
          if (s != null) {
            final m = jsonDecode(body);
            if (m is Map<String, dynamic>) scheduleMicrotask(() => s.onEvent(m));
          }
          res.statusCode = 204;
        default:
          res.statusCode = 404;
      }
    } catch (e) {
      res.statusCode = 404;
      AppLog.I.warn('Reader server couldn\'t answer ${req.uri.path.replaceFirst(_secret, '…')}: $e');
    }
    await res.close();
  }
}

class _Session {
  _Session(this.path, this.init, this.onEvent);
  final String path;
  final Map<String, dynamic> Function() init;
  final void Function(Map<String, dynamic>) onEvent;
}
