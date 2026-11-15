import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../core/books.dart';
import '../core/db.dart';
import '../core/library.dart';
import '../core/log.dart';
import '../core/paths.dart';
import '../core/reading.dart';
import '../core/server.dart';
import '../core/settings.dart';
import 'app.dart';
import 'look.dart';
import 'pdf_view.dart';
import 'widgets.dart';

/// The shared WebView2 setup (Windows), with its data kept in Sable's data folder.
class ReaderWeb {
  static WebViewEnvironment? env;
  static String? runtimeVersion;
  static bool checked = false;

  static Future<void> init() async {
    if (checked) return;
    checked = true;
    if (!Platform.isWindows) return;
    try {
      runtimeVersion = await WebViewEnvironment.getAvailableVersion();
      if (runtimeVersion == null) {
        AppLog.I.warn('The Microsoft Edge WebView2 Runtime isn\'t installed, so EPUB and MOBI books can\'t be shown. '
            'Install it from Microsoft (search "WebView2 Runtime") and restart Sable.');
        return;
      }
      env = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: p.join(AppPaths.I.data, 'WebView2')));
      AppLog.I.info('Book engine: WebView2 $runtimeVersion');
    } catch (e) {
      AppLog.I.warn('Couldn\'t start WebView2: $e');
    }
  }
}

/// For the self-test: the open reader.
class ReaderControl {
  static ReaderPageState? active;
}

class TocItem {
  TocItem(this.label, this.target, this.level);
  final String label;
  final String target; // EPUB href, or the PDF page number
  final int level;
}

/// Opens a book full-window over everything.
Future<void> openBook(BuildContext context, Book b) async {
  if (b.missing || !File(outerPath(b.path)).existsSync()) {
    toast('That book can\'t be found. Is its drive connected?', ToastKind.error);
    return;
  }
  Nav.I.readerOpen = true;
  await Navigator.of(context).push(_route(b));
  Nav.I.readerOpen = false;
  Library.I.changed();
}

PageRoute _route(Book b) => PageRouteBuilder(
      pageBuilder: (_, _, _) => ReaderPage(book: b),
      transitionDuration: const Duration(milliseconds: 160),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    );

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.book});
  final Book book;
  @override
  State<ReaderPage> createState() => ReaderPageState();
}

class ReaderPageState extends State<ReaderPage> {
  Book get book => widget.book;
  bool get isPdf => book.format == 'pdf';
  late final ReadTracker tracker;
  final FocusNode _focus = FocusNode(debugLabel: 'reader');

  String? path;
  String? error;
  String? url;
  InAppWebViewController? web;
  final PdfPagerController pdf = PdfPagerController();

  bool ready = false;
  double fraction = 0;
  String chapter = '';
  String chapterHref = '';
  int page = 0, pages = 0, pageLast = 0;
  double? minSection, minTotal;
  int loc = 0, locTotal = 0;
  List<TocItem> toc = [];
  bool chrome = false;
  String? panel; // contents | bookmarks | search | style
  bool endCard = false;
  bool lightbox = false;
  int events = 0;
  int relocations = 0;
  List<Map<String, dynamic>> results = [];
  bool searching = false;
  final searchCtl = TextEditingController();
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    tracker = ReadTracker(book);
    fraction = book.progress;
    ReaderControl.active = this;
    _clock = Timer.periodic(const Duration(seconds: 30), (_) => mounted ? setState(() {}) : null);
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      path = isInZip(book.path) ? await Library.I.extractFromZip(book.path) : book.path;
      if (!isPdf && !Platform.isWindows && !Platform.isAndroid) {
        error = 'EPUB and MOBI books can be read on Windows and Android.';
      } else if (!isPdf) {
        await ReaderWeb.init();
        if (Platform.isWindows && ReaderWeb.runtimeVersion == null) {
          error = 'EPUB and MOBI books need the Microsoft Edge WebView2 Runtime, which isn\'t installed on this PC. '
              'Install it from Microsoft (search "WebView2 Runtime"), then open the book again.';
        } else {
          await LocalServer.I.start();
          url = LocalServer.I.open(bookPath: path!, init: _init, onEvent: _onEvent);
        }
      }
    } catch (e) {
      error = 'This book couldn\'t be opened: $e';
      AppLog.I.error('Opening ${book.fileName}', e);
    }
    if (mounted) setState(() {});
  }

  /// A finished book read again starts from the beginning.
  String get _startPosition => book.isRead && book.progress >= 0.999 ? '' : book.position;

  Map<String, dynamic> _init() => {
        'style': Settings.I.style.toJson(),
        'theme': Look.I.readerTheme(),
        'position': _startPosition,
        'fileName': p.basename(path ?? book.fileName),
      };

  @override
  void dispose() {
    tracker.close();
    if (url != null) LocalServer.I.close(url!);
    if (ReaderControl.active == this) ReaderControl.active = null;
    _clock?.cancel();
    _focus.dispose();
    searchCtl.dispose();
    super.dispose();
  }

  // ---------------- events from the book engine ----------------

  void _onEvent(Map<String, dynamic> m) {
    if (!mounted) return;
    events++;
    switch (m['type']) {
      case 'ready':
        toc = [
          for (final t in (m['toc'] as List? ?? []).whereType<Map>())
            TocItem('${t['label'] ?? ''}', '${t['href'] ?? ''}', (t['level'] as num?)?.toInt() ?? 0)
        ];
        ready = true;
        AppLog.I.info('Opened ${p.basename(path ?? '')} · ${toc.length} chapters');
      case 'relocate':
        relocations++;
        fraction = ((m['fraction'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
        chapter = m['chapter'] as String? ?? '';
        chapterHref = m['chapterHref'] as String? ?? '';
        page = (m['page'] as num?)?.toInt() ?? 0;
        pages = (m['pages'] as num?)?.toInt() ?? 0;
        final l = m['location'];
        if (l is Map) {
          loc = (l['current'] as num?)?.toInt() ?? 0;
          locTotal = (l['total'] as num?)?.toInt() ?? 0;
        }
        final t = m['time'];
        if (t is Map) {
          minSection = (t['section'] as num?)?.toDouble();
          minTotal = (t['total'] as num?)?.toDouble();
        }
        tracker.moved(fraction, m['cfi'] as String? ?? '', loc);
        if (m['atEnd'] == true && !tracker.completed) _finish();
      case 'tap':
        tracker.activity();
        if (panel != null) {
          panel = null;
        } else {
          chrome = !chrome;
        }
      case 'activity':
        tracker.activity();
      case 'key':
        tracker.activity();
        _onJsKey(m['key'] as String? ?? '', ctrl: m['ctrl'] == true);
        return;
      case 'search':
        results = (m['results'] as List? ?? []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
        searching = false;
      case 'lightbox':
        lightbox = m['open'] == true;
      case 'error':
        AppLog.I.warn('Book engine: ${m['message']}');
        return;
      case 'failed':
        error = 'This book couldn\'t be opened. It may be damaged or use a format Sable can\'t read.';
        AppLog.I.error('The book engine couldn\'t open ${book.fileName}', m['message']);
    }
    setState(() {});
  }

  void _finish() {
    if (tracker.finish()) {
      endCard = true;
      chrome = false;
      panel = null;
    }
  }

  // ---------------- commands ----------------

  Future<void> cmd(String js) async {
    try {
      await web?.evaluateJavascript(source: js);
    } catch (e) {
      AppLog.I.warn('Book engine command failed: $e');
    }
  }

  void next() {
    tracker.activity();
    isPdf ? pdf.next() : cmd('sable.next()');
  }

  void prev() {
    tracker.activity();
    isPdf ? pdf.prev() : cmd('sable.prev()');
  }

  void left() => isPdf ? pdf.prev() : cmd('sable.left()');
  void right() => isPdf ? pdf.next() : cmd('sable.right()');

  void goFraction(double f) => isPdf ? pdf.goToFraction(f) : cmd('sable.goToFraction($f)');

  void goTarget(String target) {
    if (isPdf) {
      pdf.goToPage(int.tryParse(target) ?? 0);
    } else {
      cmd('sable.goTo(${jsonEncode(target)})');
    }
  }

  void _styleChanged() {
    Settings.I.save();
    if (!isPdf) cmd('sable.setStyle(${jsonEncode(Settings.I.style.toJson())})');
    setState(() {});
  }

  void _themeChanged() {
    if (!isPdf) cmd('sable.setTheme(${jsonEncode(Look.I.readerTheme())})');
    setState(() {});
  }

  void back() {
    if (lightbox) {
      cmd('sable.closeLightbox()');
      return;
    }
    if (endCard) {
      setState(() => endCard = false);
      return;
    }
    if (panel != null) {
      setState(() => panel = null);
      return;
    }
    if (Nav.I.fullScreen) {
      Nav.I.toggleFullScreen();
      return;
    }
    Navigator.of(context).maybePop();
  }

  Volume? get volume => Library.I.volumeOf(book);
  Volume? get nextVol {
    final v = volume;
    return v == null ? null : Library.I.nextVolume(v, skipRead: Settings.I.skipRead);
  }

  void openNext() {
    final n = nextVol;
    if (n == null) {
      toast('This is the last volume', ToastKind.info);
      return;
    }
    Navigator.of(context).pushReplacement(_route(n.primary));
  }

  void toggleFavourite() {
    final v = volume;
    if (v == null) return;
    Library.I.toggleFavourite([v]);
    toast(v.favourite ? 'Added to favourites' : 'Removed from favourites');
    setState(() {});
  }

  void addBookmark() {
    final pos = isPdf ? '${(fraction * (pdf.pageCount - 1)).round()}' : tracker.book.position;
    if (pos.isEmpty) return;
    final label = [if (chapter.isNotEmpty) chapter, '${(fraction * 100).round()}%'].join(' · ');
    Db.I.addBookmark(book.id, pos, label, fraction);
    toast('Bookmark added: $label');
    setState(() {});
  }

  void changeSize(double d) {
    final s = Settings.I.style;
    s.size = (s.size + d).clamp(12, 36);
    _styleChanged();
  }

  void cycleLayout() {
    final s = Settings.I.style;
    s.layout = switch (s.layout) {
      PageLayout.auto => PageLayout.one,
      PageLayout.one => PageLayout.two,
      PageLayout.two => PageLayout.auto,
    };
    toast('Pages: ${_layoutLabel(s.layout)}', ToastKind.info);
    _styleChanged();
  }

  static String _layoutLabel(PageLayout l) => switch (l) {
        PageLayout.auto => 'Auto (two when the window is wide)',
        PageLayout.one => 'One page',
        PageLayout.two => 'Two pages',
      };

  void showPanel(String name) => setState(() {
        panel = name;
        chrome = true;
      });

  void togglePanel(String name) => setState(() {
        panel = panel == name ? null : name;
        if (panel != null) chrome = true;
      });

  // ---------------- keys ----------------

  /// Keys pressed while the book page has focus (page turns already happened there).
  void _onJsKey(String key, {bool ctrl = false}) {
    switch (key) {
      case 'Escape':
        back();
      default:
        _letter(key.toLowerCase(), ctrl: ctrl);
    }
  }

  bool _letter(String k, {bool ctrl = false}) {
    if (ctrl && k == 'f') {
      togglePanel('search');
      return true;
    }
    if (ctrl) return false;
    switch (k) {
      case 't':
        togglePanel('contents');
      case 'b':
        addBookmark();
      case '/':
        togglePanel('search');
      case 'd':
        cycleLayout();
      case 'v':
        toggleFavourite();
      case 'n':
        openNext();
      case '+' || '=':
        if (!isPdf) changeSize(1);
      case '-' || '_':
        if (!isPdf) changeSize(-1);
      case 'f' || 'f11':
        Nav.I.toggleFullScreen().then((_) => windowManager.focus());
      case 'h' || 'm':
        setState(() => chrome = !chrome);
      case 'enter':
        setState(() => chrome = !chrome);
      default:
        return false;
    }
    return true;
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (typingInField) {
      if (e.logicalKey == LogicalKeyboardKey.escape) {
        FocusScope.of(context).unfocus();
        _focus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    tracker.activity();
    final k = e.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (k == LogicalKeyboardKey.escape) {
      back();
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      left();
    } else if (k == LogicalKeyboardKey.arrowRight) {
      right();
    } else if (k == LogicalKeyboardKey.pageUp) {
      prev();
    } else if (k == LogicalKeyboardKey.pageDown || k == LogicalKeyboardKey.space) {
      next();
    } else if (k == LogicalKeyboardKey.home) {
      isPdf ? pdf.first() : cmd('sable.chapterStart()');
    } else if (k == LogicalKeyboardKey.end) {
      isPdf ? pdf.last() : cmd('sable.chapterEnd()');
    } else if (k == LogicalKeyboardKey.f11) {
      Nav.I.toggleFullScreen();
    } else if (!_letter(e.character?.toLowerCase() ?? k.keyLabel.toLowerCase(), ctrl: ctrl)) {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ---------------- building ----------------

  @override
  Widget build(BuildContext context) {
    final t = tk;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: t.pageBg,
        body: ListenableBuilder(
          listenable: Nav.I,
          builder: (context, _) => Stack(children: [
            Positioned.fill(child: _engine()),
            if (!chrome && error == null) _statusLine(),
            if (chrome) _topBar(),
            if (chrome) _bottomBar(),
            if (panel != null) _panel(),
            if (endCard) _end(),
            const ToastLayer(),
          ]),
        ),
      ),
    );
  }

  Widget _engine() {
    if (error != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.menu_book_outlined, size: 30, color: tk.faint),
            const SizedBox(height: 12),
            Text(error!, style: ts(c: tk.sec), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Btn('Back to the library', onTap: () => Navigator.of(context).maybePop()),
          ]),
        ),
      );
    }
    if (path == null) return Center(child: Text('Opening…', style: ts(c: tk.faint)));
    if (isPdf) {
      final start = book.position.isEmpty || _startPosition.isEmpty ? 0 : int.tryParse(book.position) ?? 0;
      return PdfPager(
        path: path!,
        controller: pdf,
        startPage: start,
        layout: Settings.I.style.layout,
        background: tk.pageBg,
        darkPages: Settings.I.pdfDarkPages,
        onReady: (n, outline) => setState(() {
          ready = true;
          toc = [for (final o in outline) TocItem(o.label, '${o.page}', o.level)];
          AppLog.I.info('Opened ${p.basename(path!)} · $n pages');
        }),
        onPage: (first, last, count) {
          if (!mounted) return;
          events++;
          relocations++;
          fraction = count <= 1 ? 1 : last / (count - 1);
          page = first + 1;
          pageLast = last + 1;
          pages = count;
          loc = first;
          locTotal = count;
          minTotal = (count - 1 - last) * 1.2;
          minSection = null;
          chapter = '';
          for (final o in toc) {
            if (int.parse(o.target) <= first) chapter = o.label;
          }
          tracker.moved(fraction, '$first', first);
          if (last >= count - 1 && !tracker.completed) _finish();
          setState(() {});
        },
        onTapZone: (x) {
          tracker.activity();
          if (x < 0.3) {
            pdf.prev();
          } else if (x > 0.7) {
            pdf.next();
          } else {
            setState(() {
              if (panel != null) {
                panel = null;
              } else {
                chrome = !chrome;
              }
            });
          }
          _focus.requestFocus();
        },
        onError: (m) => setState(() {
          error = 'This PDF couldn\'t be opened. It may be damaged or protected.';
          AppLog.I.error('Opening the PDF ${book.fileName}', m);
        }),
      );
    }
    if (url == null) return Center(child: Text('Opening…', style: ts(c: tk.faint)));
    return InAppWebView(
      webViewEnvironment: ReaderWeb.env,
      initialUrlRequest: URLRequest(url: WebUri(url!)),
      initialSettings: InAppWebViewSettings(
        transparentBackground: false,
        supportZoom: false,
        disableContextMenu: true,
        isInspectable: false,
        javaScriptEnabled: true,
      ),
      onWebViewCreated: (c) => web = c,
      onConsoleMessage: (c, m) {
        if (m.messageLevel == ConsoleMessageLevel.ERROR) AppLog.I.warn('Book page: ${m.message}');
      },
      onReceivedError: (c, r, e) {
        if (r.isForMainFrame ?? true) {
          setState(() => error = 'The book page couldn\'t load: ${e.description}');
        }
      },
    );
  }

  String get _title {
    final v = book.volumeText;
    final base = book.inSeries ? (book.displaySeries ?? book.displayTitle) : book.displayTitle;
    return v.isEmpty ? base : '$base · $v';
  }

  String _clockText() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  String _mins(double? m) {
    if (m == null) return '';
    final x = m.round();
    if (x < 1) return 'less than a minute';
    if (x < 60) return '$x min';
    return '${x ~/ 60} h ${x % 60} min';
  }

  Widget _statusLine() {
    final c = tk.pageMuted;
    final st = ts(size: 11.5, c: c, tab: true);
    final left = isPdf
        ? (pages > 0 ? (pageLast > page ? 'Pages $page–$pageLast of $pages' : 'Page $page of $pages') : '')
        : (pages > 0 ? '${chapter.isEmpty ? 'Page' : chapter} · $page of $pages' : chapter);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: 40,
      child: IgnorePointer(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Row(children: [
            Expanded(child: Text(left, style: st, overflow: TextOverflow.ellipsis)),
            Text('${(fraction * 100).floor()}%', style: st),
            const SizedBox(width: 14),
            Text(_clockText(), style: st),
          ]),
        ),
      ),
    );
  }

  BoxDecoration get _barDeco => BoxDecoration(
        color: tk.panel.withValues(alpha: 0.96),
        border: Border.all(color: tk.line),
        borderRadius: BorderRadius.circular(lk.rPanel + 2),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 18)],
      );

  Widget _topBar() {
    final bms = Db.I.bookmarks(book.id);
    final v = volume;
    return Positioned(
      left: 10,
      right: 10,
      top: 10,
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: _barDeco,
        child: Row(children: [
          IconBtn(Icons.arrow_back, tooltip: 'Back to the library (Esc)', onTap: () => Navigator.of(context).maybePop()),
          const SizedBox(width: 8),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_title, style: ts(w: FontWeight.w600), overflow: TextOverflow.ellipsis),
              if (chapter.isNotEmpty) Text(chapter, style: ts(size: 11.5, c: tk.faint), overflow: TextOverflow.ellipsis),
            ]),
          ),
          if (!isPdf) IconBtn(Icons.search, tooltip: 'Search in the book (/)', active: panel == 'search', onTap: () => togglePanel('search')),
          IconBtn(Icons.bookmarks_outlined, tooltip: 'Bookmarks', active: panel == 'bookmarks', onTap: () => togglePanel('bookmarks')),
          IconBtn(Icons.bookmark_add_outlined, tooltip: 'Bookmark this page (B)${bms.isEmpty ? '' : ' · ${bms.length} saved'}', onTap: addBookmark),
          IconBtn(Icons.toc, tooltip: 'Contents (T)', active: panel == 'contents', onTap: () => togglePanel('contents')),
          IconBtn(Icons.text_fields, tooltip: 'Reading settings', active: panel == 'style', onTap: () => togglePanel('style')),
          IconBtn(v?.favourite == true ? Icons.favorite : Icons.favorite_border,
              tooltip: 'Favourite (V)', color: v?.favourite == true ? lk.acc : null, onTap: toggleFavourite),
          IconBtn(Nav.I.fullScreen ? Icons.fullscreen_exit : Icons.fullscreen, tooltip: 'Full screen (F)', onTap: () => Nav.I.toggleFullScreen()),
        ]),
      ),
    );
  }

  Widget _bottomBar() {
    final left = minSection == null
        ? (minTotal == null ? '' : '${_mins(minTotal)} left in the book')
        : '${_mins(minSection)} left in the chapter · ${_mins(minTotal)} left in the book';
    return Positioned(
      left: 10,
      right: 10,
      bottom: 10,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        decoration: _barDeco,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Text('${(fraction * 100).floor()}%', style: ts(w: FontWeight.w700, tab: true)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                  [
                    if (isPdf && pages > 0) pageLast > page ? 'Pages $page–$pageLast of $pages' : 'Page $page of $pages',
                    if (!isPdf && pages > 0) 'Page $page of $pages in this chapter',
                    left,
                  ].where((x) => x.isNotEmpty).join(' · '),
                  style: ts(c: tk.sec, size: 12, tab: true),
                  overflow: TextOverflow.ellipsis),
            ),
            if (nextVol != null) Btn.ghost('Next volume', icon: Icons.skip_next_outlined, dense: true, onTap: openNext),
          ]),
          const SizedBox(height: 6),
          _ProgressSlider(value: fraction, onChanged: goFraction),
        ]),
      ),
    );
  }

  Widget _panel() {
    final Widget body = switch (panel) {
      'contents' => _contents(),
      'bookmarks' => _bookmarks(),
      'search' => _search(),
      _ => _styles(),
    };
    final title = switch (panel) {
      'contents' => 'Contents',
      'bookmarks' => 'Bookmarks',
      'search' => 'Search in the book',
      _ => 'Reading settings',
    };
    return Positioned(
      right: 10,
      top: 64,
      bottom: chrome ? 96 : 10,
      width: 360,
      child: Container(
        decoration: _barDeco,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
            child: Row(children: [
              Expanded(child: Text(title, style: ts(w: FontWeight.w700))),
              IconBtn(Icons.close, tooltip: 'Close (Esc)', onTap: () => setState(() => panel = null)),
            ]),
          ),
          Expanded(child: body),
        ]),
      ),
    );
  }

  Widget _contents() {
    if (toc.isEmpty) return EmptyState(icon: Icons.toc, text: ready ? 'This book has no contents list.' : 'Loading…');
    final current = isPdf ? chapter : chapterHref;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
      itemCount: toc.length,
      itemBuilder: (_, i) {
        final it = toc[i];
        final on = isPdf ? it.label == current : it.target == current;
        return Hoverable(
          builder: (h) => GestureDetector(
            onTap: () {
              goTarget(it.target);
              setState(() => panel = null);
            },
            child: Container(
              padding: EdgeInsets.fromLTRB(10 + it.level * 14.0, 7, 10, 7),
              decoration: BoxDecoration(
                color: on ? lk.tint(tk.raised, 0.18) : (h ? tk.raised : null),
                borderRadius: BorderRadius.circular(lk.rControl),
              ),
              child: Text(it.label.isEmpty ? 'Untitled' : it.label,
                  style: ts(c: on ? tk.text : tk.sec, w: on ? FontWeight.w600 : null)),
            ),
          ),
        );
      },
    );
  }

  Widget _bookmarks() {
    final bms = Db.I.bookmarks(book.id);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Row(children: [Btn('Bookmark this page', icon: Icons.bookmark_add_outlined, onTap: addBookmark)]),
      ),
      Expanded(
        child: bms.isEmpty
            ? const EmptyState(icon: Icons.bookmark_border, text: 'No bookmarks yet.\nPress B to bookmark the page you\'re on.')
            : ListView(
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
                children: [
                  for (final b in bms)
                    Hoverable(
                      builder: (h) => GestureDetector(
                        onTap: () {
                          goTarget(b.position);
                          setState(() => panel = null);
                        },
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                          decoration: BoxDecoration(color: h ? tk.raised : null, borderRadius: BorderRadius.circular(lk.rControl)),
                          child: Row(children: [
                            Icon(Icons.bookmark, size: 16, color: lk.acc),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(b.label, style: ts(), overflow: TextOverflow.ellipsis),
                                Text(dateText(b.at), style: ts(size: 11.5, c: tk.faint)),
                              ]),
                            ),
                            IconBtn(Icons.close, tooltip: 'Remove this bookmark', onTap: () {
                              Db.I.deleteBookmark(b.id);
                              setState(() {});
                            }),
                          ]),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    ]);
  }

  Widget _search() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Field(
          controller: searchCtl,
          autofocus: true,
          hint: 'Words to find, then Enter',
          icon: Icons.search,
          onSubmitted: (q) {
            setState(() {
              searching = q.trim().isNotEmpty;
              results = [];
            });
            cmd('sable.search(${jsonEncode(q.trim())})');
          },
        ),
      ),
      if (searching)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            const SizedBox(width: 60, child: Progress(value: null, height: 4)),
            const SizedBox(width: 8),
            Text('Searching…', style: ts(c: tk.faint, size: 12)),
          ]),
        )
      else if (searchCtl.text.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text('${results.length}${results.length >= 300 ? '+' : ''} found', style: ts(c: tk.faint, size: 12)),
        ),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 10),
          itemCount: results.length,
          itemBuilder: (_, i) {
            final r = results[i];
            return Hoverable(
              builder: (h) => GestureDetector(
                onTap: () => goTarget('${r['cfi']}'),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                  decoration: BoxDecoration(color: h ? tk.raised : null, borderRadius: BorderRadius.circular(lk.rControl)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if ('${r['label']}'.isNotEmpty) Text('${r['label']}', style: ts(size: 11.5, c: tk.faint)),
                    Text.rich(
                      TextSpan(children: [
                        TextSpan(text: '${r['pre']}', style: ts(c: tk.sec)),
                        TextSpan(text: '${r['match']}', style: ts(c: lk.acc, w: FontWeight.w700)),
                        TextSpan(text: '${r['post']}', style: ts(c: tk.sec)),
                      ]),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ]),
                ),
              ),
            );
          },
        ),
      ),
    ]);
  }

  Widget _styles() {
    final s = Settings.I.style;
    Widget row(String label, Widget child) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            SizedBox(width: 92, child: Text(label, style: ts(c: tk.sec))),
            Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
          ]),
        );
    Widget sw(bool v, ValueChanged<bool> f) => Switch(value: v, onChanged: f, activeThumbColor: lk.acc);
    return ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 14), children: [
      row(
          'Theme',
          Seg<String>(
            value: Look.I.theme,
            items: const [('OLED black', 'OLED black'), ('Starlight', 'Starlight')],
            onChanged: (v) {
              Look.I.setTheme(v);
              _themeChanged();
            },
          )),
      row(
          'Pages',
          Seg<PageLayout>(
            value: s.layout,
            items: const [(PageLayout.auto, 'Auto'), (PageLayout.one, 'One'), (PageLayout.two, 'Two')],
            onChanged: (v) {
              s.layout = v;
              _styleChanged();
            },
          )),
      if (isPdf)
        row('Dark pages', sw(Settings.I.pdfDarkPages, (v) {
          Settings.I.pdfDarkPages = v;
          Settings.I.save();
          setState(() {});
        })),
      if (!isPdf) ...[
        row(
            'Font',
            Drop<String>(
              value: s.font,
              width: 200,
              items: [for (final f in readingFonts) (f, fontLabel(f))],
              onChanged: (v) {
                s.font = v;
                _styleChanged();
              },
            )),
        row(
            'Size',
            Row(children: [
              IconBtn(Icons.remove, tooltip: 'Smaller (−)', onTap: () => changeSize(-1)),
              SizedBox(width: 44, child: Text('${s.size.round()}', style: ts(w: FontWeight.w600, tab: true), textAlign: TextAlign.center)),
              IconBtn(Icons.add, tooltip: 'Bigger (+)', onTap: () => changeSize(1)),
            ])),
        row(
            'Line spacing',
            Slider(
              value: s.spacing,
              min: 1.0,
              max: 2.4,
              divisions: 14,
              onChanged: (v) => setState(() => s.spacing = v),
              onChangeEnd: (_) => _styleChanged(),
            )),
        row(
            'Margins',
            Slider(
              value: s.margin,
              min: 0,
              max: 160,
              divisions: 16,
              onChanged: (v) => setState(() => s.margin = v),
              onChangeEnd: (_) => _styleChanged(),
            )),
        row('Justify', sw(s.justify, (v) {
          s.justify = v;
          _styleChanged();
        })),
        row('Book\'s styles', sw(s.publisherStyles, (v) {
          s.publisherStyles = v;
          _styleChanged();
        })),
        row(
            'Turning',
            Seg<PageFlow>(
              value: s.flow,
              items: const [(PageFlow.paged, 'Pages'), (PageFlow.scrolled, 'Scroll')],
              onChanged: (v) {
                s.flow = v;
                _styleChanged();
              },
            )),
        row('Animation', sw(s.animate, (v) {
          s.animate = v;
          _styleChanged();
        })),
      ],
      const SizedBox(height: 8),
      Text('These apply to every book.', style: ts(size: 11.5, c: tk.faint)),
    ]);
  }

  Widget _end() {
    final v = volume;
    final n = nextVol;
    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() => endCard = false),
        child: Container(
          color: Colors.black54,
          alignment: Alignment.center,
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 400,
              padding: const EdgeInsets.all(20),
              decoration: _barDeco,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(gradient: lk.grad, shape: BoxShape.circle),
                  child: Icon(Icons.check, color: lk.onAcc),
                ),
                const SizedBox(height: 12),
                Text('Finished', style: ts(size: 16, w: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(_title, style: ts(c: tk.sec), textAlign: TextAlign.center),
                const SizedBox(height: 14),
                if (v != null) ...[
                  Stars(
                      value: v.rating,
                      size: 26,
                      onChanged: (r) {
                        Library.I.setRating(v, r);
                        setState(() {});
                      }),
                  const SizedBox(height: 10),
                  Btn.ghost(v.favourite ? 'Favourite' : 'Add to favourites',
                      icon: v.favourite ? Icons.favorite : Icons.favorite_border, onTap: toggleFavourite),
                ],
                const SizedBox(height: 16),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Btn('Back to the library', onTap: () => Navigator.of(context).maybePop()),
                  if (n != null) ...[
                    const SizedBox(width: 8),
                    Btn.primary('Next: ${n.any.volumeText.isEmpty ? n.any.displayTitle : n.any.volumeText}',
                        icon: Icons.skip_next, onTap: openNext),
                  ],
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressSlider extends StatefulWidget {
  const _ProgressSlider({required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double> onChanged;
  @override
  State<_ProgressSlider> createState() => _ProgressSliderState();
}

class _ProgressSliderState extends State<_ProgressSlider> {
  double? drag;
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 18,
      child: Slider(
        value: (drag ?? widget.value).clamp(0.0, 1.0),
        onChanged: (v) => setState(() => drag = v),
        onChangeEnd: (v) {
          widget.onChanged(v);
          setState(() => drag = null);
        },
      ),
    );
  }
}

