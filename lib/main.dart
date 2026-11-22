import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/db.dart';
import 'core/downloads.dart';
import 'core/jobs.dart';
import 'core/library.dart';
import 'core/log.dart';
import 'core/paths.dart';
import 'core/samples.dart';
import 'core/platform.dart';
import 'core/settings.dart';
import 'core/sync_client.dart';
import 'core/sync_server.dart';
import 'ui/app.dart';
import 'ui/look.dart';
import 'ui/pdf_view.dart';
import 'ui/reader_page.dart';

const appVersion = String.fromEnvironment('SABLE_VERSION', defaultValue: 'dev');
const _instancePort = 47641;
final GlobalKey _shotKey = GlobalKey();

Future<void> main(List<String> args) async {
  final selftest = args.contains('--selftest') || Platform.environment['SABLE_SELFTEST'] == '1';
  WidgetsFlutterBinding.ensureInitialized();

  // One window only: a second launch brings the first one forward.
  ServerSocket? instance;
  if (!selftest && isDesktop) {
    try {
      instance = await ServerSocket.bind(InternetAddress.loopbackIPv4, _instancePort);
    } catch (_) {
      try {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, _instancePort, timeout: const Duration(seconds: 2));
        s.write('show');
        await s.flush();
        await s.close();
      } catch (_) {}
      exit(0);
    }
  }

  if (Platform.isAndroid) {
    // The phone: small things in the app's own storage; covers and downloaded
    // books in the app's folder on the phone's storage.
    final data = await getApplicationSupportDirectory();
    final ext = await getExternalStorageDirectory();
    AppPaths.I = AppPaths.phone(data.path, ext?.path ?? data.path);
  } else {
    AppPaths.I = AppPaths.resolve();
  }
  AppLog.I.init(AppPaths.I.logs);
  AppLog.I.info('Sable $appVersion starting. Data: ${AppPaths.I.data} · Cache: ${AppPaths.I.cache}');
  _finishDataMove();

  FlutterError.onError = (d) {
    AppLog.I.error('Interface error', d.exception, d.stack);
    AppLog.I.writeCrash('drawing the interface', d.exception, d.stack);
  };
  ui.PlatformDispatcher.instance.onError = (e, st) {
    AppLog.I.error('Unexpected error', e, st);
    AppLog.I.writeCrash('running', e, st);
    return true;
  };

  Settings.I.load();
  Look.I.load();
  if (selftest && !isPhone) _prepareSelftest();

  // Safe mode after two unclean exits in a row. (Not on the phone, where the
  // system ends apps without telling them.)
  final marker = File(p.join(AppPaths.I.data, 'running.marker'));
  var unclean = 0;
  if (!isPhone) {
    if (marker.existsSync()) unclean = (int.tryParse(marker.readAsStringSync().trim()) ?? 0) + 1;
    marker.writeAsStringSync('$unclean');
  }
  final safeMode = unclean >= 2;
  if (unclean >= 1) _reportNativeCrash();
  if (safeMode) {
    AppLog.I.warn('Sable didn\'t close properly twice in a row, so folder watching and background cover making '
        'are off for this run. They come back next time Sable starts after closing normally.');
    Covers.I.safeMode = true;
  }

  Db.I = Db.open(AppPaths.I.db);
  Db.I.backup(AppPaths.I.backups);
  if (!AppPaths.I.ensureCache()) {
    AppLog.I.warn('The cache folder ${AppPaths.I.cache} can\'t be reached. Is its drive connected? Covers won\'t be saved until it is.');
  }
  Library.I.pdfInspector = inspectPdfFile;
  if (isPhone) {
    // Everything the phone changes goes in the outbox for the PC.
    Db.I.recordChanges = true;
    SyncClient.I.load();
    Downloads.I.init();
    Library.I.onDevice = Downloads.I.isDone;
  }
  Library.I.load();

  if (isPhone && !Platform.isAndroid) {
    // The phone app on a computer (for tests): a phone-shaped window.
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
        const WindowOptions(size: Size(412, 892), title: 'Sable (phone)', backgroundColor: Colors.black), () async {
      await windowManager.show();
    });
  }
  if (isDesktop) {
    await windowManager.ensureInitialized();
    final ws = Settings.I.windowState;
    final opts = WindowOptions(
      size: Size((ws['w'] as num?)?.toDouble() ?? 1440, (ws['h'] as num?)?.toDouble() ?? 900),
      minimumSize: const Size(1100, 680),
      center: ws['x'] == null,
      title: 'Sable',
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Look.I.t.ground,
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      if (ws['x'] != null) {
        await windowManager.setPosition(Offset((ws['x'] as num).toDouble(), (ws['y'] as num).toDouble()));
      }
      if (ws['max'] == true) await windowManager.maximize();
      await windowManager.show();
      await windowManager.focus();
    });
    windowManager.addListener(_WindowKeeper(marker));
    await windowManager.setPreventClose(true);
  }

  instance?.listen((s) {
    s.listen((_) async {
      await windowManager.show();
      await windowManager.restore();
      await windowManager.focus();
    });
  });

  // Flutter's Windows accessibility bridge crashes (null AXNode in
  // AccessibilityBridge::CreateRemoveReparentedNodesUpdate) when an
  // accessibility client — a screen reader, or an app that reads other
  // windows through UI Automation — is active while the library grid
  // rebuilds. Sable doesn't offer screen-reader support, so the semantics
  // tree is kept empty and the bridge has nothing to reparent.
  runApp(RepaintBoundary(key: _shotKey, child: const ExcludeSemantics(child: SableApp())));

  WidgetsBinding.instance.addPostFrameCallback((_) async {
    if (selftest) {
      await _runSelftest();
      return;
    }
    unawaited(_trimBookCache());
    if (isPhone) {
      // Sync now, every few minutes, and whenever the app comes back to the front.
      SyncClient.I.startAuto();
      unawaited(_phoneSync());
      phoneLifecycle = AppLifecycleListener(onResume: () => unawaited(_phoneSync()));
    } else {
      if (safeMode) Settings.I.watchFolders = false;
      // A quick rescan picks up anything added while Sable was closed;
      // unchanged books are skipped, so this is fast.
      Library.I.scan();
      Library.I.startWatching();
      unawaited(SyncServer.I.start());
    }
    // A heartbeat in the log file: memory and what's running, every 30 seconds,
    // so the log shows what Sable was doing if it ever stops unexpectedly.
    Timer.periodic(const Duration(seconds: 30), (_) {
      final j = Jobs.I.current;
      AppLog.I.fileOnly('Heartbeat · memory ${ProcessInfo.currentRss ~/ (1024 * 1024)} MB'
          '${j == null ? ' · idle' : ' · ${j.name} ${j.done}/${j.total ?? '?'}'}'
          '${Nav.I.readerOpen ? ' · reading' : ' · ${Nav.I.screenName}'}');
    });
  });
}

AppLifecycleListener? phoneLifecycle;

/// A quiet sync (an unreachable PC isn't an error: the phone is just away from home).
Future<void> _phoneSync() async {
  if (!SyncClient.I.paired) return;
  try {
    await SyncClient.I.sync(quiet: true);
    if (SyncClient.I.online) Downloads.I.retryWaiting();
  } catch (_) {}
}

class _WindowKeeper with WindowListener {
  _WindowKeeper(this.marker);
  final File marker;
  Timer? _save;

  void _remember() {
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 600), () async {
      final max = await windowManager.isMaximized();
      final ws = Settings.I.windowState;
      ws['max'] = max;
      if (!max && !await windowManager.isFullScreen()) {
        final b = await windowManager.getBounds();
        ws['x'] = b.left;
        ws['y'] = b.top;
        ws['w'] = b.width;
        ws['h'] = b.height;
      }
      Settings.I.save();
    });
  }

  @override
  void onWindowResized() => _remember();
  @override
  void onWindowMoved() => _remember();
  @override
  void onWindowMaximize() => _remember();
  @override
  void onWindowUnmaximize() => _remember();

  @override
  void onWindowClose() async {
    // The window goes at once; saving happens behind it.
    try {
      await windowManager.hide();
    } catch (_) {}
    // A book open in the reader records its session now.
    try {
      ReaderControl.active?.tracker.close();
    } catch (_) {}
    Jobs.I.stop();
    try {
      await SyncServer.I.stop();
    } catch (_) {}
    try {
      Db.I.close();
    } catch (_) {}
    try {
      marker.deleteSync();
    } catch (_) {}
    AppLog.I.info('Closed');
    await AppLog.I.flush();
    // Everything is saved: end the process straight away rather than waiting
    // for the book engine (WebView2), the folder watchers and background work
    // to wind down one by one, which is what made closing slow.
    exit(0);
  }
}

/// After a crash outside Dart code, the runner leaves a short report in the logs.
void _reportNativeCrash() {
  try {
    final files = Directory(AppPaths.I.logs)
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path).startsWith('native-crash-') && f.path.endsWith('.txt'))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    if (files.isEmpty) {
      _previousRunTail();
      AppLog.I.warn('Sable didn\'t close properly last time, and left no crash report.');
      return;
    }
    final f = files.first;
    _previousRunTail();
    if (DateTime.now().difference(f.statSync().modified).inDays > 2) return;
    AppLog.I.warn('Sable stopped unexpectedly last time. Report: ${f.path}\n${f.readAsStringSync().trim()}');
  } catch (_) {}
}

/// The end of the previous run's log, copied into this one after a crash.
void _previousRunTail() {
  try {
    final prev = AppLog.I.previousFile;
    if (prev == null) return;
    final lines = File(prev).readAsLinesSync();
    AppLog.I.fileOnly('--- last lines of the previous run (${p.basename(prev)}) ---');
    for (final l in lines.skip(lines.length > 40 ? lines.length - 40 : 0)) {
      AppLog.I.fileOnly('  $l');
    }
    AppLog.I.fileOnly('--- end of the previous run ---');
  } catch (_) {}
}

/// Books copied out of ZIPs are kept for a while, then cleared down to 1 GB.
Future<void> _trimBookCache() async {
  try {
    final d = Directory(AppPaths.I.bookCache);
    if (!await d.exists()) return;
    final files = await d.list().where((e) => e is File).cast<File>().toList();
    final stats = <(File, FileStat)>[for (final f in files) (f, await f.stat())]
      ..sort((a, b) => b.$2.accessed.compareTo(a.$2.accessed));
    var total = 0;
    for (final (f, st) in stats) {
      total += st.size;
      if (total > 1024 * 1024 * 1024) await f.delete();
    }
  } catch (_) {}
}

/// After "Move…" of the data folder: the new place is in use, so the old copy goes.
void _finishDataMove() {
  try {
    final base = Platform.environment['LOCALAPPDATA'];
    if (base == null) return;
    final pointer = File(AppPaths.pointerFileFor(p.join(base, 'Sable')));
    if (!pointer.existsSync()) return;
    final m = jsonDecode(pointer.readAsStringSync()) as Map;
    final old = m['old'] as String?;
    if (old == null || old == AppPaths.I.data) return;
    if (!File(p.join(AppPaths.I.data, 'library.db')).existsSync()) return;
    for (final name in ['library.db', 'library.db-wal', 'library.db-shm', 'settings.json', 'appearance.json']) {
      final f = File(p.join(old, name));
      if (f.existsSync()) f.deleteSync();
    }
    for (final d in ['logs', 'backups', 'WebView2']) {
      final dir = Directory(p.join(old, d));
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    m.remove('old');
    pointer.writeAsStringSync(jsonEncode(m));
    AppLog.I.info('Finished moving the data folder to ${AppPaths.I.data}');
  } catch (e) {
    AppLog.I.warn('Couldn\'t tidy up after moving the data folder: $e');
  }
}

// ---------------- self-test (CI) ----------------

String get _selftestBooks => p.join(AppPaths.I.root, 'selftest-books');

void _prepareSelftest() {
  final root = Directory(_selftestBooks);
  if (root.existsSync()) root.deleteSync(recursive: true);
  final ln = Directory(p.join(root.path, 'LIGHT NOVELS', 'Starlight Saga'))..createSync(recursive: true);
  final books = Directory(p.join(root.path, 'BOOKS'))..createSync(recursive: true);
  for (var v = 1; v <= 3; v++) {
    File(p.join(ln.path, 'Starlight Saga - Vol. $v.epub')).writeAsBytesSync(
        makeSampleEpub(title: 'Starlight Saga Volume $v', author: 'Test Writer', chapters: 4, paragraphs: 30, hue: v * 40));
  }
  // The same volume 2 as a PDF: it must show as one volume with two formats.
  File(p.join(ln.path, 'Starlight Saga - Vol. 2.pdf')).writeAsBytesSync(makeSamplePdf(6, 'Starlight Saga 2'));
  File(p.join(books.path, 'A Quiet Book.epub'))
      .writeAsBytesSync(makeSampleEpub(title: 'A Quiet Book', author: 'Someone Else', chapters: 3, paragraphs: 20, hue: 200));
  File(p.join(books.path, 'Picture Notes.pdf')).writeAsBytesSync(makeSamplePdf(5, 'Picture Notes'));
  Settings.I.folders = [
    LibFolder(p.join(root.path, 'LIGHT NOVELS'), kind: Kind.ln),
    LibFolder(p.join(root.path, 'BOOKS')),
  ];
  Settings.I.style.animate = false;
  AppLog.I.info('Self-test: made sample books in ${root.path}');
}

Future<void> _waitJobs([int seconds = 120]) async {
  final until = DateTime.now().add(Duration(seconds: seconds));
  while ((Jobs.I.current != null || Jobs.I.queue.isNotEmpty) && DateTime.now().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}

Future<void> _runSelftest() async {
  // Turn accessibility on, as a screen reader or UI Automation client would,
  // so the self-test goes through the path that crashed in 1.1.0.
  final semantics = SemanticsBinding.instance.ensureSemantics();
  var ok = true;
  final out = StringBuffer();
  void check(bool c, String what) {
    out.writeln('${c ? 'OK  ' : 'FAIL'} $what');
    if (!c) ok = false;
  }

  // With a phone self-test running beside this one: serve it.
  final peer = Platform.environment['SABLE_SYNC_PEER'] == '1';
  if (isPhone) return _runPhoneSelftest(semantics);
  try {
    Library.I.scan();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _waitJobs();
    if (peer) await SyncServer.I.start();
    final books = Library.I.books;
    check(books.length == 6, 'scan found 6 book files (found ${books.length})');
    final vols = Library.I.volumes;
    check(vols.length == 5, 'the EPUB and PDF of volume 2 count as one volume (${vols.length} volumes)');
    final series = Library.I.series;
    check(series.length == 1 && series.values.first.length == 3, 'volumes grouped into one series');
    final pdfs = books.where((b) => b.format == 'pdf').toList();
    check(pdfs.isNotEmpty && pdfs.every((b) => b.pages > 0), 'PDF page counts read (${pdfs.map((b) => b.pages).join(', ')})');
    final covers = books.where((b) => Covers.I.cached(b) != null).length;
    check(covers == 6, 'covers made ($covers of 6)');
    // Covers that go missing (cache cleared) are made again.
    Covers.I.cached(books.first)?.deleteSync();
    Covers.I.queueMissing();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _waitJobs();
    check(Covers.I.cached(books.first) != null, 'missing covers are made again');
    final epub = books.firstWhere((b) => b.format == 'epub' && b.volume == 1);
    check(epub.displayAuthor == 'Test Writer', 'author read from the EPUB');
    check(epub.textBytes > 10000, 'book length measured (${epub.length} pages)');
    await Future<void>.delayed(const Duration(seconds: 1));
    await _screenshot('library');

    // What crashed on Windows: accessibility on, the library grid changing fast.
    for (var i = 0; i < 40; i++) {
      Settings.I.tileSize = i.isEven ? 110 : 300;
      Settings.I.save();
      Library.I.changed();
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    Settings.I.tileSize = 168;
    Settings.I.save();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    check(true, 'survived rapid grid resizing with accessibility on');

    // Book and series pages.
    final s = Library.I.entries().whereType<SeriesEntry>().first;
    Nav.I.openEntry(s);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await _screenshot('series');
    Nav.I.openVolume(vols[epub.volumeKey]!);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await _screenshot('book');
    Nav.I.closeDetail();

    // EPUB reader.
    final ctx = navKey.currentContext;
    if (ctx != null && ctx.mounted) {
      unawaited(openBook(ctx, epub));
      final until = DateTime.now().add(const Duration(seconds: 40));
      while (DateTime.now().isBefore(until) && (ReaderControl.active == null || ReaderControl.active!.relocations == 0)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      final r = ReaderControl.active;
      check(r != null, 'reader opened');
      if (r != null) {
        check(r.ready, 'the book engine opened the EPUB (${r.toc.length} chapters)');
        check(r.relocations > 0, 'the book engine reported the reading position');
        final before = r.fraction;
        for (var i = 0; i < 3; i++) {
          r.next();
          await Future<void>.delayed(const Duration(milliseconds: 600));
        }
        check(r.fraction > before, 'turning pages moves on (${(before * 100).toStringAsFixed(1)}% → ${(r.fraction * 100).toStringAsFixed(1)}%)');
        await _screenshot('reader');
        // Separate margins and a text colour.
        final st = Settings.I.style;
        st.marginXPct = 15;
        st.marginYPct = 10;
        st.textColor = '#ffd27a';
        r.cmd('sable.setStyle(${jsonEncode(st.toJson())})');
        await Future<void>.delayed(const Duration(milliseconds: 900));
        await _screenshot('reader-margins-colour');
        st.apply(ReadingStyle().toJson());
        r.cmd('sable.setStyle(${jsonEncode(st.toJson())})');
        // Space keeps the controls up; M opens them as a keyboard menu.
        r.togglePinned();
        check(r.chrome && r.pinned, 'Space shows the controls and keeps them');
        r.openMenu();
        r.menuKey('ArrowRight');
        r.menuKey('ArrowRight');
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await _screenshot('reader-menu');
        check(r.menu && r.menuIndex == 2, 'the controls menu moves with the arrow keys');
        r.menuKey('Escape');
        check(!r.menu, 'Esc closes the controls menu');
        r.togglePinned();
        check(!r.chrome, 'Space again hides the controls');
        r.showPanel('style');
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await _screenshot('reader-settings');
        r.goFraction(0.999);
        await Future<void>.delayed(const Duration(seconds: 2));
        for (var i = 0; i < 6 && !r.tracker.completed; i++) {
          r.next();
          await Future<void>.delayed(const Duration(milliseconds: 600));
        }
        check(r.tracker.completed, 'reaching the end records the book as finished');
        await _screenshot('reader-end');
        // Pretend some reading time passed, so the session is kept.
        r.tracker.activeSeconds += 30;
      }
      navKey.currentState?.popUntil((x) => x.isFirst);
      await Future<void>.delayed(const Duration(seconds: 1));
      check(Db.I.sessions(bookId: epub.id).isNotEmpty, 'reading session recorded');
      check(epub.readCount == 1, 'read count went up (${epub.readCount})');

      // PDF reader.
      final pdf = books.firstWhere((b) => b.format == 'pdf' && b.volume == null);
      final ctx2 = navKey.currentContext;
      if (ctx2 != null && ctx2.mounted) unawaited(openBook(ctx2, pdf));
      final until2 = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(until2) && (ReaderControl.active == null || ReaderControl.active!.relocations == 0)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      final r2 = ReaderControl.active;
      check(r2 != null && r2.pages == 5, 'PDF opened with 5 pages (${r2?.pages})');
      if (r2 != null) {
        r2.next();
        await Future<void>.delayed(const Duration(seconds: 1));
        await _screenshot('reader-pdf');
        r2.toggleCrop();
        await Future<void>.delayed(const Duration(seconds: 1));
        await _screenshot('reader-pdf-cropped');
        r2.toggleCrop();
      }
      navKey.currentState?.popUntil((x) => x.isFirst);
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }

    for (final (page, name) in [
      (PageId.history, 'history'),
      (PageId.stats, 'stats'),
      (PageId.settings, 'settings'),
    ]) {
      Nav.I.go(page);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await _screenshot(name);
    }
    // Back and forward (the mouse's side buttons) move through where you've been.
    Nav.I.back();
    check(Nav.I.page == PageId.stats, 'back goes to the page before');
    Nav.I.forward();
    check(Nav.I.page == PageId.settings, 'forward comes back');
    // Editing a theme, then putting it back.
    Look.I.setToken('ground', const Color(0xFF101018));
    check(Look.I.t.ground == const Color(0xFF101018) && Look.I.themeEdited('OLED black'), 'theme colours can be changed');
    Look.I.resetTheme('OLED black');
    check(Look.I.t.ground == const Color(0xFF000000) && !Look.I.themeEdited('OLED black'), 'theme reset puts them back');
    Look.I.appScale = 1.2;
    Look.I.save();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _screenshot('settings-120');
    Look.I.appScale = 1.0;
    Look.I.save();
    Look.I.setTheme('Starlight');
    Nav.I.go(PageId.library);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await _screenshot('library-starlight');
    // Books / light novels and library-folder filters.
    final lf = Library.I.filter;
    lf.ln = Tri.no;
    final onlyBooks = Library.I.entries().length;
    lf.ln = Tri.any;
    final all = Library.I.entries().length;
    check(onlyBooks > 0 && onlyBooks <= all, 'Books-only filter ($onlyBooks of $all)');
    lf.folders = {Settings.I.folders.first.path};
    final inFolder = Library.I.entries().length;
    check(inFolder > 0, 'library folder filter ($inFolder in ${Settings.I.folders.first.path})');
    Library.I.changed();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _screenshot('library-filtered');
    Library.I.filter = LibFilter();
    Library.I.changed();
    Nav.I.toggle('keys');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _screenshot('keys');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    Nav.I.toggle('keys');
    if (peer) {
      // The phone pairs, downloads, reads and changes things, then syncs back.
      final until = DateTime.now().add(const Duration(seconds: 240));
      bool phoneDone() {
        Library.I.load();
        final quiet = Library.I.books.where((b) => b.displayTitle == 'A Quiet Book').firstOrNull;
        return quiet != null && quiet.favourite && SyncServer.I.phones.isNotEmpty;
      }

      while (DateTime.now().isBefore(until) && !phoneDone()) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      check(SyncServer.I.phones.isNotEmpty, 'PC: the phone paired with the code');
      check(phoneDone(), 'PC: the phone\'s favourite arrived');
      final notes = Library.I.books.where((b) => b.displayTitle == 'Picture Notes').firstOrNull;
      check(notes != null && notes.readCount == 1, 'PC: the phone\'s "mark read" arrived (times read ${notes?.readCount})');
      final phoneSessions = Db.I.sessions().where((x) => x.device == 'Phone').length;
      check(phoneSessions >= 1, 'PC: the phone\'s reading session arrived ($phoneSessions)');
      Nav.I.go(PageId.settings);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await _screenshot('pc-settings-phone');
      Nav.I.go(PageId.history);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await _screenshot('pc-history-after-phone');
      // Give the phone time for its last sync before this side closes.
      await Future<void>.delayed(const Duration(seconds: 8));
    }
    check(AppLog.I.errorCount == 0, 'no errors logged (${AppLog.I.errorCount})');
  } catch (e, st) {
    ok = false;
    out.writeln('FAIL exception: $e\n$st');
  }
  semantics.dispose();
  final report = 'SELFTEST ${ok ? 'PASSED' : 'FAILED'}\n$out\n--- log ---\n${AppLog.I.lines.join('\n')}';
  File(p.join(AppPaths.I.logs, 'selftest.txt')).writeAsStringSync(report);
  stdout.writeln(report);
  await AppLog.I.flush();
  try {
    File(p.join(AppPaths.I.data, 'running.marker')).deleteSync();
  } catch (_) {}
  exit(ok ? 0 : 1);
}

/// The phone app's self-test, against a PC self-test running beside it.
Future<void> _runPhoneSelftest(SemanticsHandle semantics) async {
  var ok = true;
  final out = StringBuffer();
  void check(bool c, String what) {
    out.writeln('${c ? 'OK  ' : 'FAIL'} $what');
    if (!c) ok = false;
  }

  try {
    await Future<void>.delayed(const Duration(seconds: 1));
    await _screenshot('phone-empty');
    // Find the PC and pair with the code it shows.
    List<FoundPc> found = [];
    final until = DateTime.now().add(const Duration(seconds: 90));
    while (found.isEmpty && DateTime.now().isBefore(until)) {
      found = await SyncClient.I.discover();
      if (found.isEmpty) await Future<void>.delayed(const Duration(seconds: 2));
    }
    check(found.isNotEmpty, 'found the PC on the network (${found.map((f) => '${f.name} ${f.host}').join(', ')})');
    final host = found.isNotEmpty ? found.first.host : '127.0.0.1';
    try {
      await SyncClient.I.pair(host, syncPort, '000000', device: 'Wrong code test');
      check(false, 'a wrong code is refused');
    } on SyncError catch (e) {
      check(true, 'a wrong code is refused ("${e.message}")');
    }
    await SyncClient.I.pair(host, syncPort, Platform.environment['SABLE_PAIR_CODE'] ?? '', device: 'Test phone');
    check(SyncClient.I.paired, 'paired with ${SyncClient.I.pcName}');

    // The PC may still be scanning: sync until the whole library is here.
    final until2 = DateTime.now().add(const Duration(seconds: 90));
    do {
      await SyncClient.I.sync();
      if (Library.I.books.length >= 6) break;
      await Future<void>.delayed(const Duration(seconds: 3));
    } while (DateTime.now().isBefore(until2));
    final books = Library.I.books;
    check(books.length == 6, 'library came from the PC (${books.length} books, ${Library.I.volumes.length} volumes)');
    final covers = books.where((b) => Covers.I.cached(b) != null).length;
    check(covers == 6, 'covers came from the PC ($covers of 6)');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await _screenshot('phone-library');

    // Download a book and a PDF.
    final quiet = books.firstWhere((b) => b.displayTitle == 'A Quiet Book');
    final notes = books.firstWhere((b) => b.displayTitle == 'Picture Notes');
    Downloads.I.add([quiet, notes]);
    final until3 = DateTime.now().add(const Duration(seconds: 60));
    while (Downloads.I.queue.isNotEmpty && DateTime.now().isBefore(until3)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final f1 = Downloads.I.fileFor(quiet), f2 = Downloads.I.fileFor(notes);
    check(f1 != null && File(f1).lengthSync() == quiet.size, 'downloaded the EPUB (${f1 == null ? 'missing' : File(f1).lengthSync()} of ${quiet.size} bytes)');
    check(f2 != null && File(f2).lengthSync() == notes.size, 'downloaded the PDF');
    Library.I.filter.downloaded = Tri.yes;
    Library.I.changed();
    check(Library.I.entries().length == 2, 'the Downloaded filter shows just those two (${Library.I.entries().length})');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _screenshot('phone-library-downloaded');
    Library.I.filter.downloaded = Tri.any;
    Library.I.changed();

    Nav.I.go(PageId.downloads);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _screenshot('phone-downloads');
    Nav.I.go(PageId.library);
    final s = Library.I.entries().whereType<SeriesEntry>().first;
    Nav.I.openEntry(s);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await _screenshot('phone-series');
    Nav.I.openVolume(Library.I.volumeOf(quiet)!);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await _screenshot('phone-book');
    Nav.I.closeDetail();

    // Read the downloaded PDF for a while (a session needs 10 s or more).
    final ctx = navKey.currentContext;
    if (ctx != null && ctx.mounted) {
      unawaited(openBook(ctx, notes));
      final until4 = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(until4) && (ReaderControl.active == null || !ReaderControl.active!.ready)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      final r = ReaderControl.active;
      check(r != null && r.ready, 'the downloaded PDF opened');
      if (r != null) {
        r.next();
        await Future<void>.delayed(const Duration(milliseconds: 600));
        r.togglePinned();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await _screenshot('phone-reader');
        r.togglePinned();
        r.tracker.activeSeconds = 30; // as if read for half a minute
        await Future<void>.delayed(const Duration(seconds: 1));
        navKey.currentState?.pop();
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }

    // Changes on the phone: a favourite and a "mark read".
    Library.I.toggleFavourite([Library.I.volumeOf(quiet)!], true);
    Library.I.markRead([Library.I.volumeOf(notes)!], true);
    final pending = Db.I.outbox().length;
    check(pending >= 3, 'changes waiting to send ($pending)');
    await SyncClient.I.sync();
    check(Db.I.outbox().isEmpty, 'changes sent (outbox empty)');
    final q2 = Library.I.books.firstWhere((b) => b.uid == quiet.uid);
    final n2 = Library.I.books.firstWhere((b) => b.uid == notes.uid);
    check(q2.favourite, 'the favourite is still there after the PC\'s copy came back');
    check(n2.readCount == 1 && n2.isRead, 'the PC counted the phone\'s "mark read" (times read ${n2.readCount})');
    final sessions = Db.I.sessions(bookId: n2.id);
    check(sessions.any((x) => x.device == 'Phone'), 'the phone\'s reading session is in the PC\'s history');

    Nav.I.go(PageId.history);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await _screenshot('phone-history');
    Nav.I.go(PageId.stats);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await _screenshot('phone-stats');
    Nav.I.go(PageId.settings);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await _screenshot('phone-settings');
    Nav.I.go(PageId.library);
    check(AppLog.I.errorCount == 0, 'no errors logged (${AppLog.I.errorCount})');
  } catch (e, st) {
    ok = false;
    out.writeln('FAIL exception: $e\n$st');
  }
  semantics.dispose();
  final report = 'SELFTEST ${ok ? 'PASSED' : 'FAILED'}\n$out\n--- log ---\n${AppLog.I.lines.join('\n')}';
  File(p.join(AppPaths.I.logs, 'selftest.txt')).writeAsStringSync(report);
  stdout.writeln(report);
  await AppLog.I.flush();
  exit(ok ? 0 : 1);
}

Future<void> _screenshot(String name) async {
  try {
    final ro = _shotKey.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary) return;
    final im = await ro.toImage(pixelRatio: 1);
    final png = await im.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) return;
    final path = p.join(AppPaths.I.logs, 'selftest-$name.png');
    File(path).writeAsBytesSync(png.buffer.asUint8List());
    AppLog.I.info('Self-test screenshot: $path (${im.width}×${im.height})');
  } catch (e) {
    AppLog.I.warn('Self-test screenshot failed: $e');
  }
}
