import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'core/db.dart';
import 'core/jobs.dart';
import 'core/library.dart';
import 'core/log.dart';
import 'core/paths.dart';
import 'core/samples.dart';
import 'core/settings.dart';
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
  if (!selftest && (Platform.isWindows || Platform.isLinux)) {
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

  AppPaths.I = AppPaths.resolve();
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
  if (selftest) _prepareSelftest();

  // Safe mode after two unclean exits in a row.
  final marker = File(p.join(AppPaths.I.data, 'running.marker'));
  var unclean = 0;
  if (marker.existsSync()) unclean = (int.tryParse(marker.readAsStringSync().trim()) ?? 0) + 1;
  marker.writeAsStringSync('$unclean');
  final safeMode = unclean >= 2;
  if (safeMode) {
    AppLog.I.warn('Sable didn\'t close properly twice in a row, so folder watching is off for this run. '
        'Turn it back on in Settings → Library.');
  }

  Db.I = Db.open(AppPaths.I.db);
  Db.I.backup(AppPaths.I.backups);
  if (!AppPaths.I.ensureCache()) {
    AppLog.I.warn('The cache folder ${AppPaths.I.cache} can\'t be reached. Is its drive connected? Covers won\'t be saved until it is.');
  }
  Library.I.pdfInspector = inspectPdfFile;
  Library.I.load();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
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

  runApp(RepaintBoundary(key: _shotKey, child: const SableApp()));

  WidgetsBinding.instance.addPostFrameCallback((_) async {
    if (selftest) {
      await _runSelftest();
      return;
    }
    if (safeMode) Settings.I.watchFolders = false;
    // A quick rescan picks up anything added while Sable was closed;
    // unchanged books are skipped, so this is fast.
    Library.I.scan();
    Library.I.startWatching();
    unawaited(_trimBookCache());
  });
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
    // Closing the reader records the session.
    navKey.currentState?.popUntil((r) => r.isFirst);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    Jobs.I.stop();
    try {
      Db.I.close();
    } catch (_) {}
    try {
      marker.deleteSync();
    } catch (_) {}
    await AppLog.I.flush();
    await windowManager.destroy();
  }
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
  var ok = true;
  final out = StringBuffer();
  void check(bool c, String what) {
    out.writeln('${c ? 'OK  ' : 'FAIL'} $what');
    if (!c) ok = false;
  }

  try {
    Library.I.scan();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _waitJobs();
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
    final epub = books.firstWhere((b) => b.format == 'epub' && b.volume == 1);
    check(epub.displayAuthor == 'Test Writer', 'author read from the EPUB');
    check(epub.textBytes > 10000, 'book length measured (${epub.length} pages)');
    await Future<void>.delayed(const Duration(seconds: 1));
    await _screenshot('library');

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
    if (ctx != null) {
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
    Look.I.setTheme('Starlight');
    Nav.I.go(PageId.library);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await _screenshot('library-starlight');
    Nav.I.toggle('keys');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _screenshot('keys');
    Nav.I.toggle('keys');
    check(AppLog.I.errorCount == 0, 'no errors logged (${AppLog.I.errorCount})');
  } catch (e, st) {
    ok = false;
    out.writeln('FAIL exception: $e\n$st');
  }
  final report = 'SELFTEST ${ok ? 'PASSED' : 'FAILED'}\n$out\n--- log ---\n${AppLog.I.lines.join('\n')}';
  File(p.join(AppPaths.I.logs, 'selftest.txt')).writeAsStringSync(report);
  stdout.writeln(report);
  await AppLog.I.flush();
  try {
    File(p.join(AppPaths.I.data, 'running.marker')).deleteSync();
  } catch (_) {}
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
