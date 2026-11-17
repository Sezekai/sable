import 'dart:io';

/// The phone app (Android). `SABLE_PHONE=1` runs the phone app on a computer,
/// for testing the phone screens and sync without a phone.
final bool isPhone = Platform.isAndroid || Platform.environment['SABLE_PHONE'] == '1';

/// The PC app, with its own window (Windows, or Linux for tests).
final bool isDesktop = !isPhone && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
