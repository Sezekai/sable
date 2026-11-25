import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// A few Windows calls, for putting Sable's window on the screen it was
// opened from. Everything is in the screen's real pixels, so screens with
// different scaling don't throw it off.

final class _Point extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

final class _Rect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

final class _MonitorInfo extends Struct {
  @Uint32()
  external int cbSize;
  external _Rect rcMonitor;
  external _Rect rcWork;
  @Uint32()
  external int dwFlags;
}

class WinScreen {
  static DynamicLibrary? _u;
  static DynamicLibrary get _user32 => _u ??= DynamicLibrary.open('user32.dll');

  /// Sable's own top-level window.
  static int _ownWindow() {
    final findEx = _user32.lookupFunction<IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
        int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
    final threadPid = _user32.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
        'GetWindowThreadProcessId');
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final out = calloc<Uint32>();
    try {
      var h = 0;
      while (true) {
        h = findEx(0, h, cls, nullptr);
        if (h == 0) return 0;
        threadPid(h, out);
        if (out.value == pid) return h;
      }
    } finally {
      calloc.free(cls);
      calloc.free(out);
    }
  }

  /// Moves the (not yet maximised) window onto the screen the mouse pointer
  /// is on, filling its work area, so maximising keeps it there. False if it
  /// couldn't.
  static bool moveToPointerScreen() {
    if (!Platform.isWindows) return false;
    final pt = calloc<_Point>();
    final mi = calloc<_MonitorInfo>();
    try {
      final getCursorPos = _user32.lookupFunction<Int32 Function(Pointer<_Point>), int Function(Pointer<_Point>)>('GetCursorPos');
      final monitorFromPoint = _user32.lookupFunction<IntPtr Function(_Point, Uint32), int Function(_Point, int)>('MonitorFromPoint');
      final getMonitorInfo = _user32.lookupFunction<Int32 Function(IntPtr, Pointer<_MonitorInfo>), int Function(int, Pointer<_MonitorInfo>)>(
          'GetMonitorInfoW');
      final setWindowPos = _user32.lookupFunction<Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
          int Function(int, int, int, int, int, int, int)>('SetWindowPos');
      if (getCursorPos(pt) == 0) return false;
      final mon = monitorFromPoint(pt.ref, 2 /* MONITOR_DEFAULTTONEAREST */);
      if (mon == 0) return false;
      mi.ref.cbSize = sizeOf<_MonitorInfo>();
      if (getMonitorInfo(mon, mi) == 0) return false;
      final h = _ownWindow();
      if (h == 0) return false;
      final w = mi.ref.rcWork;
      // SWP_NOZORDER | SWP_NOACTIVATE
      return setWindowPos(h, 0, w.left, w.top, w.right - w.left, w.bottom - w.top, 0x0004 | 0x0010) != 0;
    } catch (_) {
      return false;
    } finally {
      calloc.free(pt);
      calloc.free(mi);
    }
  }

  /// Ends the process at once, without running the shutdown code of the
  /// libraries it loaded (the book engine's could crash while winding down).
  static Never terminate(int code) {
    if (Platform.isWindows) {
      try {
        final k = DynamicLibrary.open('kernel32.dll');
        final cur = k.lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
        final term = k.lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>('TerminateProcess');
        term(cur(), code);
      } catch (_) {}
    }
    exit(code);
  }
}
