#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <dbghelp.h>
#include <psapi.h>

#include <cstdio>
#include <string>

#include "flutter_window.h"
#include "utils.h"

// If Sable crashes outside its Dart code (a native library, the book engine
// host, the graphics driver), this writes a short report and a small dump to
// the logs folder, so the cause can be found.
static std::wstring SableLogsDir() {
  wchar_t buf[MAX_PATH * 2];
  DWORD n = ::GetEnvironmentVariableW(L"SABLE_DATA", buf, MAX_PATH * 2);
  std::wstring base;
  if (n > 0 && n < MAX_PATH * 2) {
    base = buf;
  } else {
    n = ::GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH * 2);
    if (n == 0 || n >= MAX_PATH * 2) return L"";
    base = std::wstring(buf) + L"\\Sable";
  }
  std::wstring logs = base + L"\\logs";
  ::CreateDirectoryW(base.c_str(), nullptr);
  ::CreateDirectoryW(logs.c_str(), nullptr);
  return logs;
}

static LONG WINAPI SableCrashHandler(EXCEPTION_POINTERS* info) {
  std::wstring logs = SableLogsDir();
  if (logs.empty()) return EXCEPTION_CONTINUE_SEARCH;
  SYSTEMTIME t;
  ::GetLocalTime(&t);
  wchar_t stamp[64];
  swprintf_s(stamp, L"%04d-%02d-%02dT%02d-%02d-%02d", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
  std::wstring txt = logs + L"\\native-crash-" + stamp + L".txt";
  std::wstring dmp = logs + L"\\native-crash-" + stamp + L".dmp";

  void* addr = info && info->ExceptionRecord ? info->ExceptionRecord->ExceptionAddress : nullptr;
  DWORD code = info && info->ExceptionRecord ? info->ExceptionRecord->ExceptionCode : 0;
  HMODULE mod = nullptr;
  wchar_t modName[MAX_PATH] = L"(unknown)";
  if (addr && ::GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                   static_cast<LPCWSTR>(addr), &mod)) {
    ::GetModuleFileNameW(mod, modName, MAX_PATH);
  }
  FILE* f = nullptr;
  if (_wfopen_s(&f, txt.c_str(), L"w, ccs=UTF-8") == 0 && f) {
    fwprintf(f, L"Sable stopped unexpectedly (native crash).\n");
    fwprintf(f, L"Time: %s\n", stamp);
    fwprintf(f, L"Exception code: 0x%08lX\n", static_cast<unsigned long>(code));
    fwprintf(f, L"Address: %p\n", addr);
    fwprintf(f, L"Module: %s\n", modName);
    if (mod) {
      fwprintf(f, L"Offset in module: 0x%llX\n",
               static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(addr) - reinterpret_cast<uintptr_t>(mod)));
    }
    fclose(f);
  }
  HANDLE h = ::CreateFileW(dmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h != INVALID_HANDLE_VALUE) {
    MINIDUMP_EXCEPTION_INFORMATION mei;
    mei.ThreadId = ::GetCurrentThreadId();
    mei.ExceptionPointers = info;
    mei.ClientPointers = FALSE;
    ::MiniDumpWriteDump(::GetCurrentProcess(), ::GetCurrentProcessId(), h,
                        static_cast<MINIDUMP_TYPE>(MiniDumpWithThreadInfo | MiniDumpWithIndirectlyReferencedMemory),
                        info ? &mei : nullptr, nullptr, nullptr);
    ::CloseHandle(h);
  }
  return EXCEPTION_CONTINUE_SEARCH;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::SetUnhandledExceptionFilter(SableCrashHandler);

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Sable", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
