import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'books.dart';
import 'db.dart';
import 'library.dart';
import 'log.dart';
import 'paths.dart';
import 'settings.dart';
import 'sync_protocol.dart';

/// Fixed ports, so the phone can find the PC.
const syncPort = 47650;
const discoveryPort = 47651;
const discoveryAsk = 'SABLE-WHERE-ARE-YOU';

/// A phone that's been paired with this PC.
class PairedPhone {
  PairedPhone(this.name, this.token, this.added, this.lastSeen);
  String name;
  final String token;
  final int added;
  int lastSeen;
  Map<String, dynamic> toJson() => {'name': name, 'token': token, 'added': added, 'lastSeen': lastSeen};
  static PairedPhone fromJson(Map m) =>
      PairedPhone(m['name'] as String? ?? 'Phone', m['token'] as String, m['added'] as int? ?? 0, m['lastSeen'] as int? ?? 0);
}

/// The PC side of phone sync: a small web server on the home network that
/// only answers phones paired with a code shown on this PC.
///
/// What it offers a paired phone: the library and all reading records, the
/// covers, and the book files the phone asks to download. It never changes or
/// deletes book files.
class SyncServer extends ChangeNotifier {
  SyncServer._();
  static final SyncServer I = SyncServer._();

  HttpServer? _http;
  RawDatagramSocket? _udp;
  bool enabled = true;
  String pcId = '';
  String code = '';
  List<PairedPhone> phones = [];
  String status = 'Off';
  String? problem;
  int lastSyncAt = 0;
  String lastSyncText = '';

  String get _file => p.join(AppPaths.I.data, 'sync.json');

  void _load() {
    try {
      final f = File(_file);
      if (f.existsSync()) {
        final m = jsonDecode(f.readAsStringSync()) as Map;
        enabled = m['enabled'] as bool? ?? true;
        pcId = m['pcId'] as String? ?? '';
        code = m['code'] as String? ?? '';
        phones = ((m['phones'] as List?) ?? []).whereType<Map>().map(PairedPhone.fromJson).toList();
      }
    } catch (_) {}
    if (pcId.isEmpty) pcId = newUid();
    if (code.isEmpty) code = _newCode();
    // For the automatic tests: a fixed pairing code.
    final testCode = Platform.environment['SABLE_PAIR_CODE'];
    if (testCode != null && testCode.isNotEmpty) code = testCode;
    _save();
  }

  void _save() {
    try {
      writeStringSafelySync(
          _file,
          const JsonEncoder.withIndent('  ').convert({
            'enabled': enabled,
            'pcId': pcId,
            'code': code,
            'phones': phones.map((x) => x.toJson()).toList(),
          }));
    } catch (_) {}
  }

  static String _newCode() => List.generate(6, (_) => Random.secure().nextInt(10)).join();

  /// Reads the saved pairing before anything shows it.
  void ensureLoaded() {
    if (pcId.isEmpty) _load();
  }

  void newCode() {
    code = _newCode();
    _save();
    notifyListeners();
  }

  void removePhone(PairedPhone ph) {
    phones.remove(ph);
    _save();
    notifyListeners();
  }

  Future<void> setEnabled(bool on) async {
    enabled = on;
    _save();
    if (on) {
      await start();
    } else {
      await stop();
    }
    notifyListeners();
  }

  /// This PC's addresses on the home network, to type into the phone if it
  /// can't find the PC by itself.
  Future<List<String>> addresses() async {
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return [
        for (final ni in list)
          for (final a in ni.addresses)
            if (!a.isLoopback && !a.address.startsWith('169.254.')) a.address,
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> start() async {
    if (pcId.isEmpty) _load();
    if (!enabled || _http != null) {
      status = enabled ? status : 'Off';
      notifyListeners();
      return;
    }
    try {
      _http = await HttpServer.bind(InternetAddress.anyIPv4, syncPort);
      _http!.autoCompress = true;
      _http!.listen(_handle, onError: (e) => AppLog.I.warn('Phone sync: $e'));
      problem = null;
      status = 'Ready';
      AppLog.I.info('Phone sync ready on port $syncPort');
    } catch (e) {
      problem = 'Port $syncPort is in use by another program, so the phone can\'t connect. ($e)';
      status = 'Not running';
      AppLog.I.warn('Phone sync couldn\'t start: $e');
    }
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort);
      _udp!.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final dg = _udp?.receive();
        if (dg == null || utf8.decode(dg.data, allowMalformed: true).trim() != discoveryAsk) return;
        final reply = utf8.encode(jsonEncode({'sable': true, 'name': Platform.localHostname, 'port': syncPort, 'id': pcId}));
        _udp?.send(reply, dg.address, dg.port);
      });
    } catch (e) {
      AppLog.I.warn('The phone can\'t find this PC by itself (port $discoveryPort is busy: $e). It can still connect by typing the address.');
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _http?.close(force: true);
    _http = null;
    _udp?.close();
    _udp = null;
    status = 'Off';
  }

  // ---------------- requests ----------------

  PairedPhone? _auth(HttpRequest req) {
    final t = req.headers.value('x-sable-token');
    if (t == null) return null;
    for (final ph in phones) {
      if (ph.token == t) return ph;
    }
    return null;
  }

  Future<Map<String, dynamic>> _json(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    return body.isEmpty ? {} : (jsonDecode(body) as Map).cast<String, dynamic>();
  }

  void _send(HttpResponse res, Object body) {
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
  }

  int _wrongCodes = 0;
  DateTime _lockedUntil = DateTime(0);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (path == '/pair' && req.method == 'POST') {
        // Too many wrong codes: wait a minute (a 6-digit code can't be guessed quickly).
        if (DateTime.now().isBefore(_lockedUntil)) {
          res.statusCode = 429;
          _send(res, {'error': 'Too many wrong codes. Wait a minute and try again.'});
        } else {
          final m = await _json(req);
          if ((m['code'] as String?)?.trim() == code) {
            _wrongCodes = 0;
            final token = List.generate(32, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
            final name = (m['device'] as String?)?.trim();
            phones.add(PairedPhone(name == null || name.isEmpty ? 'Phone' : name, token, nowSec(), nowSec()));
            code = _newCode(); // each code works once
            final testCode = Platform.environment['SABLE_PAIR_CODE'];
            if (testCode != null && testCode.isNotEmpty) code = testCode;
            _save();
            notifyListeners();
            AppLog.I.info('Paired with ${phones.last.name}');
            _send(res, {'token': token, 'pc': Platform.localHostname, 'pcId': pcId, 'version': syncVersion});
          } else {
            if (++_wrongCodes >= 5) {
              _wrongCodes = 0;
              _lockedUntil = DateTime.now().add(const Duration(minutes: 1));
            }
            res.statusCode = 403;
            _send(res, {'error': 'That code isn\'t right. Check the code in Sable on the PC (Settings → Phone).'});
          }
        }
        await res.close();
        return;
      }
      final ph = _auth(req);
      if (ph == null) {
        res.statusCode = 401;
        _send(res, {'error': 'This phone isn\'t paired with this PC any more. Pair it again.'});
        await res.close();
        return;
      }
      ph.lastSeen = nowSec();
      switch (path) {
        case '/api/hello':
          _send(res, {
            'pc': Platform.localHostname,
            'pcId': pcId,
            'version': syncVersion,
            'books': Library.I.books.length,
          });
        case '/api/sync':
          final m = await _json(req);
          final ops = ((m['ops'] as List?) ?? []).whereType<Map>().map((x) => x.cast<String, dynamic>()).toList();
          final n = ops.isEmpty ? 0 : applyOps(Db.I, ops);
          if (ops.isNotEmpty) {
            Library.I.load();
            Library.I.changed();
          }
          lastSyncAt = nowSec();
          lastSyncText = '${ph.name} sent ${ops.length} change${ops.length == 1 ? '' : 's'}';
          if (ops.isNotEmpty) AppLog.I.info('Phone sync: ${ph.name} sent ${ops.length} changes, $n applied');
          _save();
          notifyListeners();
          _send(res, {'received': ops.length, 'applied': n});
        case '/api/snapshot':
          final snap = buildSnapshot(Db.I);
          snap['folders'] = Settings.I.folders.map((f) => f.toJson()).toList();
          snap['pc'] = Platform.localHostname;
          _send(res, snap);
        case '/api/covers':
          // Several covers in one answer: for each, the fingerprint's length (2 bytes),
          // the fingerprint, the picture's length (4 bytes) and the picture.
          final m = await _json(req);
          final out = BytesBuilder(copy: false);
          for (final fp in ((m['fps'] as List?) ?? []).whereType<String>()) {
            final f = File(Covers.I.fileForFp(fp));
            if (fp.contains('/') || fp.contains('\\') || !f.existsSync()) continue;
            final bytes = await f.readAsBytes();
            final fb = utf8.encode(fp);
            out.add((ByteData(2)..setUint16(0, fb.length)).buffer.asUint8List());
            out.add(fb);
            out.add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List());
            out.add(bytes);
          }
          res.headers.contentType = ContentType.binary;
          res.add(out.takeBytes());
        default:
          if (path.startsWith('/api/book/')) {
            await _book(req, path.substring('/api/book/'.length));
          } else {
            res.statusCode = 404;
          }
      }
    } catch (e, st) {
      AppLog.I.error('Phone sync request ${req.uri.path}', e, st);
      try {
        res.statusCode = 500;
        _send(res, {'error': '$e'});
      } catch (_) {}
    }
    try {
      await res.close();
    } catch (_) {}
  }

  /// A book file for the phone to download. Supports resuming (Range).
  Future<void> _book(HttpRequest req, String uid) async {
    final res = req.response;
    final b = Library.I.books.where((x) => x.uid == uid).firstOrNull;
    if (b == null || b.missing) {
      res.statusCode = 404;
      _send(res, {'error': 'That book isn\'t on the PC any more.'});
      return;
    }
    final path = isInZip(b.path) ? await Library.I.extractFromZip(b.path) : b.path;
    final f = File(path);
    if (!f.existsSync()) {
      res.statusCode = 404;
      _send(res, {'error': 'That book can\'t be found on the PC. Is its drive connected?'});
      return;
    }
    final len = await f.length();
    var start = 0;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    final mm = range == null ? null : RegExp(r'bytes=(\d+)-').firstMatch(range);
    if (mm != null) start = int.parse(mm.group(1)!).clamp(0, len);
    res.headers.contentType = ContentType.binary;
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    // Already compressed (EPUB, PDF): sending it as it is is faster.
    res.headers.set(HttpHeaders.contentEncodingHeader, 'identity');
    if (start > 0) {
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${len - 1}/$len');
    }
    res.contentLength = len - start;
    await res.addStream(f.openRead(start));
  }
}
