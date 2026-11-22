import 'dart:io';

import 'log.dart';

/// Opening ebook files with Sable on Windows (double-click an .epub, say).
///
/// Sable registers itself for the current user only (nothing needs admin
/// rights) as a program that can open these files. Windows doesn't let apps
/// make themselves the default, so Sable then opens Windows' own Default apps
/// page, where you pick Sable once.
class FileAssoc {
  static const exts = ['.epub', '.mobi', '.azw3', '.azw'];
  static const progId = 'Sable.Ebook';

  static String get exe => Platform.resolvedExecutable;

  static Future<bool> _reg(List<String> args) async {
    try {
      final r = await Process.run('reg', args);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _query(String key, [String? value]) async {
    try {
      final r = await Process.run('reg', ['query', key, if (value == null) '/ve' else ...['/v', value]]);
      if (r.exitCode != 0) return null;
      final line = (r.stdout as String).split('\n').firstWhere((l) => l.contains('REG_'), orElse: () => '');
      final i = line.indexOf('REG_SZ');
      return i < 0 ? null : line.substring(i + 6).trim();
    } catch (_) {
      return null;
    }
  }

  /// Is Sable registered as able to open ebooks, from where it is now?
  static Future<bool> registered() async {
    if (!Platform.isWindows) return false;
    final cmd = await _query(r'HKCU\Software\Classes\' '$progId' r'\shell\open\command');
    return cmd != null && cmd.toLowerCase().contains(exe.toLowerCase());
  }

  /// Was Sable registered before (maybe from an older folder)?
  static Future<bool> wasRegistered() async =>
      Platform.isWindows && await _query(r'HKCU\Software\Classes\' '$progId' r'\shell\open\command') != null;

  /// Registers (or re-registers, after the app moved) Sable for ebook files.
  static Future<bool> register() async {
    if (!Platform.isWindows) return false;
    final cls = r'HKCU\Software\Classes\' '$progId';
    final open = '"$exe" "%1"';
    var ok = await _reg(['add', cls, '/ve', '/d', 'Ebook', '/f']);
    ok &= await _reg(['add', '$cls\\DefaultIcon', '/ve', '/d', '"$exe",0', '/f']);
    ok &= await _reg(['add', '$cls\\shell\\open\\command', '/ve', '/d', open, '/f']);
    // Shown in "Open with" for each type.
    for (final e in exts) {
      ok &= await _reg(['add', r'HKCU\Software\Classes\' '$e' r'\OpenWithProgids', '/v', progId, '/t', 'REG_NONE', '/f']);
    }
    // Listed in Windows' Default apps.
    const caps = r'HKCU\Software\Sable\Capabilities';
    ok &= await _reg(['add', caps, '/v', 'ApplicationName', '/d', 'Sable', '/f']);
    ok &= await _reg(['add', caps, '/v', 'ApplicationDescription', '/d', 'Books and light novels', '/f']);
    for (final e in exts) {
      ok &= await _reg(['add', '$caps\\FileAssociations', '/v', e, '/d', progId, '/f']);
    }
    ok &= await _reg(['add', r'HKCU\Software\RegisteredApplications', '/v', 'Sable', '/d', r'Software\Sable\Capabilities', '/f']);
    final app = r'HKCU\Software\Classes\Applications\' '${exe.split(r'\').last}';
    ok &= await _reg(['add', '$app\\shell\\open\\command', '/ve', '/d', open, '/f']);
    for (final e in exts) {
      ok &= await _reg(['add', '$app\\SupportedTypes', '/v', e, '/d', '', '/f']);
    }
    AppLog.I.info(ok ? 'Registered Sable for ebook files ($exe)' : 'Registering Sable for ebook files didn\'t fully work');
    return ok;
  }

  /// Opens Windows' Default apps page at Sable.
  static Future<void> openDefaultApps() async {
    try {
      await Process.run('cmd', ['/c', 'start', '', 'ms-settings:defaultapps?registeredAppUser=Sable']);
    } catch (_) {}
  }

  /// Keeps the registration pointing at this copy of Sable (the App folder
  /// may have been replaced or moved).
  static Future<void> refresh() async {
    if (!Platform.isWindows) return;
    if (await wasRegistered() && !await registered()) await register();
  }
}
