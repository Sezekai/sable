import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
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
import '../core/platform.dart';
import '../core/settings.dart';
import '../core/sync_client.dart';
import 'app.dart';
import 'look.dart';
import 'phone.dart';
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
        AppLog.I.warn(
          'The Microsoft Edge WebView2 Runtime isn\'t installed, so EPUB and MOBI books can\'t be shown. '
          'Install it from Microsoft (search "WebView2 Runtime") and restart Sable.',
        );
        return;
      }
      env = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(userDataFolder: p.join(AppPaths.I.data, 'WebView2')),
      );
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
  String? file;
  if (isPhone) {
    // The phone: the downloaded copy, or the book fetched from the PC now.
    file = await phoneBookFile(context, b);
    if (file == null || !context.mounted) return;
  } else if (b.missing || !File(outerPath(b.path)).existsSync()) {
    toast('That book can\'t be found. Is its drive connected?', ToastKind.error);
    return;
  }
  Nav.I.readerOpen = true;
  if (isPhone) phoneReaderMode(true);
  await Navigator.of(context).push(_route(b, file));
  if (isPhone) phoneReaderMode(false);
  Nav.I.readerOpen = false;
  Library.I.changed();
  // Reading done on the phone goes to the PC straight away when it's reachable.
  // (Just after the reader has closed and saved the session.)
  if (isPhone && SyncClient.I.paired) {
    unawaited(Future<void>.delayed(const Duration(milliseconds: 900), () => SyncClient.I.sync(quiet: true)).catchError((_) {}));
  }
}

PageRoute _route(Book b, String? file) => PageRouteBuilder(
  pageBuilder: (_, _, _) => ReaderPage(book: b, file: file),
  transitionDuration: const Duration(milliseconds: 160),
  transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
);

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.book, this.file});
  final Book book;

  /// The file to read, when it isn't [book]'s own path (the phone's copy).
  final String? file;
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

  // The controls: the mouse brings them up for a moment; Space pins them; M opens
  // them as a keyboard menu.
  bool pinned = false;

  /// Phone: the rest of the top controls are showing; the bottom bar shows all its text.
  bool moreOpen = false;
  bool bottomOpen = false;
  bool menu = false;
  int menuIndex = 0;
  bool cursorHidden = false;
  final Set<String> _hover = {};
  Timer? _hideTimer;
  Offset? _lastPointer;
  DateTime _quietUntil = DateTime(0);
  String _lastKey = '';
  DateTime _lastKeyAt = DateTime(0);

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
      path = widget.file ?? (isInZip(book.path) ? await Library.I.extractFromZip(book.path) : book.path);
      if (!isPdf && !Platform.isWindows && !Platform.isAndroid) {
        error = 'EPUB and MOBI books can be read on Windows and Android.';
      } else if (!isPdf) {
        await ReaderWeb.init();
        if (Platform.isWindows && ReaderWeb.runtimeVersion == null) {
          error =
              'EPUB and MOBI books need the Microsoft Edge WebView2 Runtime, which isn\'t installed on this PC. '
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
    // No more commands to the book page while it's being taken down.
    web = null;
    tracker.close();
    if (url != null) LocalServer.I.close(url!);
    if (ReaderControl.active == this) ReaderControl.active = null;
    _clock?.cancel();
    _hideTimer?.cancel();
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
            TocItem('${t['label'] ?? ''}', '${t['href'] ?? ''}', (t['level'] as num?)?.toInt() ?? 0),
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
        _tapMiddle();
        return;
      case 'move':
        // Touch screens send a mouse move with every tap: only real mice count.
        if (!isPhone) _moved();
        return;
      case 'activity':
        tracker.activity();
      case 'key':
        tracker.activity();
        if (m['typing'] == true) {
          _typeKey(m['key'] as String? ?? '', m['ctrl'] == true);
          return;
        }
        _onJsKey(m['key'] as String? ?? '', ctrl: m['ctrl'] == true);
        return;
      case 'search':
        results = (m['results'] as List? ?? []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
        searching = false;
      case 'lightbox':
        lightbox = m['open'] == true;
      case 'mouse':
        _mouse(m['button'] as String? ?? '');
        return;
      case 'error':
        final msg = '${m['message']}';
        // Harmless browser notice while the page lays itself out.
        if (!msg.contains('ResizeObserver loop')) AppLog.I.warn('Book engine: $msg');
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
    if (!mounted) return;
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
    if (Nav.I.keysOpen) {
      Nav.I.toggle('keys');
      return;
    }
    if (lightbox) {
      cmd('sable.closeLightbox()');
      return;
    }
    if (endCard) {
      setState(() => endCard = false);
      return;
    }
    if (menu) {
      closeMenu();
      return;
    }
    if (panel != null) {
      setState(() => panel = null);
      return;
    }
    if (pinned) {
      setState(() {
        pinned = false;
        chrome = false;
      });
      return;
    }
    if (Nav.I.fullScreen && !isPhone) {
      Nav.I.toggleFullScreen();
      return;
    }
    Navigator.of(context).pop();
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
    if (isPhone) {
      phoneBookFile(context, n.primary).then((f) {
        if (f != null && mounted) Navigator.of(context).pushReplacement(_route(n.primary, f));
      });
      return;
    }
    Navigator.of(context).pushReplacement(_route(n.primary, null));
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
    s.size = (s.size + d).clamp(10, 48);
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

  /// The mouse's back and forward buttons: turn pages, or leave the reader.
  void _mouse(String button) {
    tracker.activity();
    if (Settings.I.mouseInReader == 'leave') {
      if (button == 'back') back();
      return;
    }
    button == 'back' ? prev() : next();
  }

  // ---------------- keys ----------------

  /// The same key can arrive twice (from the book page and from the app);
  /// act on it once.
  bool _dupe(String key) {
    final now = DateTime.now();
    final d = key == _lastKey && now.difference(_lastKeyAt) < const Duration(milliseconds: 120);
    _lastKey = key;
    _lastKeyAt = now;
    return d;
  }

  /// Keys pressed while the book page has focus (page turns already happened there).
  void _onJsKey(String key, {bool ctrl = false}) {
    if (_dupe(key.toLowerCase())) return;
    if (menu && menuKey(key)) return;
    switch (key) {
      case 'Escape':
        back();
      case ' ':
        togglePinned();
      default:
        _letter(key.toLowerCase(), ctrl: ctrl);
    }
  }

  // ---------------- showing and hiding the controls ----------------

  static const _idle = Duration(milliseconds: 2500);

  /// The mouse moved over the page: show the controls and the pointer for a moment.
  void _moved() {
    if (!mounted || endCard || DateTime.now().isBefore(_quietUntil)) return;
    tracker.activity();
    final change = !chrome || cursorHidden;
    chrome = true;
    if (cursorHidden) _setCursor(false);
    _hideTimer?.cancel();
    _hideTimer = Timer(_idle, _idleNow);
    if (change) setState(() {});
  }

  /// The mouse has stopped: hide the pointer, and the controls unless they're in use.
  void _idleNow() {
    if (!mounted) return;
    final over = _hover.isNotEmpty;
    if (!over) _setCursor(true);
    if (!(pinned || menu || panel != null || over || lightbox)) chrome = false;
    setState(() {});
  }

  void _setCursor(bool hidden) {
    if (cursorHidden == hidden) return;
    cursorHidden = hidden;
    if (!isPdf) cmd('sable.setCursor($hidden)');
  }

  /// A click in the middle of the page (or anywhere while the menu is open).
  void _tapMiddle() {
    setState(() {
      if (menu) {
        closeMenu(rebuild: false);
      } else if (panel != null) {
        panel = null;
      } else if (chrome) {
        chrome = false;
        pinned = false;
        // The click itself nudges the mouse; don't bring the controls straight back.
        _quietUntil = DateTime.now().add(const Duration(milliseconds: 600));
      } else {
        chrome = true;
        pinned = true;
      }
    });
  }

  /// Space: keep the controls up until Space or Esc again.
  void togglePinned() => setState(() {
    if (pinned) {
      pinned = false;
      chrome = false;
      if (menu) closeMenu(rebuild: false);
    } else {
      pinned = true;
      chrome = true;
    }
  });

  /// The controls along the top, in order, for the bar and for the M menu.
  /// The controls along the top, in order, for the bar and for the M menu.
  /// On a folded phone the first five show (back, search, contents, settings,
  /// text & spacing) and the rest are behind "More".
  List<_Ctl> get _controls {
    final v = volume;
    final bms = Db.I.bookmarks(book.id);
    return [
      _Ctl(Icons.arrow_back, 'Back', 'Back to the library (Esc)', () => Navigator.of(context).pop()),
      if (!isPdf)
        _Ctl(Icons.search, 'Search', 'Search in the book (/)', () => togglePanel('search'), active: panel == 'search', closes: true),
      _Ctl(Icons.toc, 'Contents', 'Contents (T)', () => togglePanel('contents'), active: panel == 'contents', closes: true),
      _Ctl(Icons.tune, 'Settings', 'Reader settings (S)', () => togglePanel('style'), active: panel == 'style', closes: true),
      if (!isPdf)
        _Ctl(Icons.format_size, 'Text', 'Text & spacing (A)', () => togglePanel('text'), active: panel == 'text', closes: true),
      _Ctl(
        Icons.bookmarks_outlined,
        'Bookmarks',
        'Bookmarks${bms.isEmpty ? '' : ' · ${bms.length} saved'}',
        () => togglePanel('bookmarks'),
        active: panel == 'bookmarks',
        closes: true,
      ),
      _Ctl(Icons.bookmark_add_outlined, 'Mark page', 'Bookmark this page (B)', addBookmark),
      _Ctl(
        v?.favourite == true ? Icons.favorite : Icons.favorite_border,
        'Favourite',
        'Favourite (V)',
        toggleFavourite,
        color: v?.favourite == true ? lk.acc : null,
      ),
      if (isPdf) _Ctl(Icons.crop, 'Crop', 'Crop the page borders (C)', toggleCrop, active: Settings.I.pdfCrop),
      if (!isPhone)
        _Ctl(
          Nav.I.fullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
          'Full screen',
          'Full screen (F)',
          () => Nav.I.toggleFullScreen().then((_) => isDesktop ? windowManager.focus() : null),
        ),
    ];
  }

  void toggleCrop() {
    Settings.I.pdfCrop = !Settings.I.pdfCrop;
    Settings.I.save();
    toast(Settings.I.pdfCrop ? 'Cropping page borders' : 'Showing whole pages', ToastKind.info);
    setState(() {});
  }

  void toggleMenu() => menu ? closeMenu() : openMenu();

  void openMenu() {
    setState(() {
      menu = true;
      chrome = true;
      menuIndex = menuIndex.clamp(0, _controls.length - 1);
    });
    _hideTimer?.cancel();
    if (!isPdf) cmd('sable.setMenu(true)');
    _focus.requestFocus();
  }

  void closeMenu({bool rebuild = true}) {
    menu = false;
    if (!isPdf) cmd('sable.setMenu(false)');
    if (!pinned && _hover.isEmpty) chrome = false;
    if (rebuild) setState(() {});
  }

  /// Keys while the menu is open. Returns true when the key was used.
  bool menuKey(String key) {
    final n = _controls.length;
    switch (key) {
      case 'ArrowLeft' || 'ArrowUp':
        setState(() => menuIndex = (menuIndex - 1 + n) % n);
      case 'ArrowRight' || 'ArrowDown' || 'Tab':
        setState(() => menuIndex = (menuIndex + 1) % n);
      case 'Home':
        setState(() => menuIndex = 0);
      case 'End':
        setState(() => menuIndex = n - 1);
      case ' ' || 'Enter':
        final c = _controls[menuIndex.clamp(0, n - 1)];
        if (c.closes) closeMenu(rebuild: false);
        c.onTap();
        setState(() {});
      case 'Escape' || 'm' || 'M':
        closeMenu();
      default:
        return false;
    }
    return true;
  }

  bool _letter(String k, {bool ctrl = false}) {
    if (ctrl && k == 'f') {
      togglePanel('search');
      return true;
    }
    if (ctrl && k == 'w' && isDesktop) {
      windowManager.close();
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
        Nav.I.toggleFullScreen().then((_) => isDesktop ? windowManager.focus() : null);
      case 'm':
        toggleMenu();
      case 'h' || 'enter':
        togglePinned();
      case 's':
        togglePanel('style');
      case 'a':
        if (!isPdf) togglePanel('text');
      case 'c':
        if (isPdf) toggleCrop();
      case 'k':
        Nav.I.toggle('keys');
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
    final name = _keyName(k, e.character);
    if (e is KeyDownEvent && _dupe(name.toLowerCase())) return KeyEventResult.handled;
    if (menu && menuKey(name)) return KeyEventResult.handled;
    if (k == LogicalKeyboardKey.escape) {
      back();
    } else if (k == LogicalKeyboardKey.space) {
      if (e is KeyDownEvent) togglePinned();
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      left();
    } else if (k == LogicalKeyboardKey.arrowRight) {
      right();
    } else if (k == LogicalKeyboardKey.pageUp) {
      prev();
    } else if (k == LogicalKeyboardKey.pageDown) {
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

  /// A key's name as the book page reports it, so both routes match.
  static String _keyName(LogicalKeyboardKey k, String? ch) {
    if (k == LogicalKeyboardKey.arrowLeft) return 'ArrowLeft';
    if (k == LogicalKeyboardKey.arrowRight) return 'ArrowRight';
    if (k == LogicalKeyboardKey.arrowUp) return 'ArrowUp';
    if (k == LogicalKeyboardKey.arrowDown) return 'ArrowDown';
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) return 'Enter';
    if (k == LogicalKeyboardKey.escape) return 'Escape';
    if (k == LogicalKeyboardKey.space) return ' ';
    if (k == LogicalKeyboardKey.tab) return 'Tab';
    if (k == LogicalKeyboardKey.home) return 'Home';
    if (k == LogicalKeyboardKey.end) return 'End';
    if (k == LogicalKeyboardKey.pageUp) return 'PageUp';
    if (k == LogicalKeyboardKey.pageDown) return 'PageDown';
    return (ch != null && ch.isNotEmpty) ? ch : k.keyLabel;
  }

  /// Notes when the mouse is over a set of controls, so they don't hide under it.
  Widget _hoverZone(String name, Widget child) =>
      MouseRegion(onEnter: (_) => _hover.add(name), onExit: (_) => _hover.remove(name), child: child);

  // ---------------- building ----------------

  @override
  Widget build(BuildContext context) {
    _syncTyping();
    final t = tk;
    // Hidden controls can't be under the mouse (their regions don't report leaving).
    if (!chrome) _hover.removeWhere((h) => h != 'panel');
    if (panel == null) _hover.remove('panel');
    return PopScope(
      // Android's back gesture steps back like Esc: closes what's open, then the book.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) back();
      },
      child: Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: t.pageBg,
        body: ListenableBuilder(
          listenable: Nav.I,
          builder: (context, _) => Listener(
            // The mouse's back and forward buttons (over a PDF or the bars).
            onPointerDown: (e) {
              if (e.buttons & kBackMouseButton != 0) _mouse('back');
              if (e.buttons & kForwardMouseButton != 0) _mouse('forward');
            },
            onPointerHover: (e) {
              final last = _lastPointer;
              _lastPointer = e.position;
              if (last == null || (e.position - last).distance > 2) _moved();
            },
            child: MouseRegion(
              cursor: cursorHidden ? SystemMouseCursors.none : MouseCursor.defer,
              child: Stack(
                children: [
                  // The book itself is drawn at the screen's own size, so it stays sharp.
                  // A phone can keep the text clear of the camera notch and the status line.
                  Positioned(
                    left: 0,
                    right: 0,
                    top: isPhone && Settings.I.style.clearNotch ? MediaQuery.viewPaddingOf(context).top : 0,
                    bottom: isPhone && Settings.I.style.clearStatus
                        ? (_statusH * Look.I.readerScale + MediaQuery.viewPaddingOf(context).bottom)
                        : 0,
                    child: UiScale(scale: 1 / Look.I.appScale, child: _engine()),
                  ),
                  // The bars and panels follow "Reader controls size".
                  Positioned.fill(
                    child: UiScale(
                      scale: Look.I.readerScale,
                      child: SafeArea(child: Stack(
                        children: [
                          if (!chrome && error == null) _statusLine(),
                          if (chrome && !(isPhone && panel != null)) _topBar(),
                          if (chrome && !(isPhone && panel != null)) _bottomBar(),
                          if (panel != null) _panel(),
                          if (endCard) _end(),
                          const ToastLayer(),
                        ],
                      )),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _engine() {
    if (error != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_outlined, size: 30, color: tk.faint),
              const SizedBox(height: 12),
              Text(
                error!,
                style: ts(c: tk.sec),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Btn('Back to the library', onTap: () => Navigator.of(context).pop()),
            ],
          ),
        ),
      );
    }
    if (path == null)
      return Center(
        child: Text('Opening…', style: ts(c: tk.faint)),
      );
    if (isPdf) {
      final start = book.position.isEmpty || _startPosition.isEmpty ? 0 : int.tryParse(book.position) ?? 0;
      return PdfPager(
        path: path!,
        controller: pdf,
        startPage: start,
        layout: Settings.I.style.layout,
        background: tk.pageBg,
        darkPages: Settings.I.pdfDarkPages,
        crop: Settings.I.pdfCrop,
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
          if (menu) {
            _tapMiddle();
          } else if (x < 0.3) {
            pdf.prev();
          } else if (x > 0.7) {
            pdf.next();
          } else {
            _tapMiddle();
          }
          _focus.requestFocus();
        },
        onError: (m) => setState(() {
          error = 'This PDF couldn\'t be opened. It may be damaged or protected.';
          AppLog.I.error('Opening the PDF ${book.fileName}', m);
        }),
      );
    }
    if (url == null)
      return Center(
        child: Text('Opening…', style: ts(c: tk.faint)),
      );
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
      height: isPhone ? _statusH : 40,
      child: IgnorePointer(
        child: Padding(
          // A phone: low down and out in the corners.
          padding: EdgeInsets.symmetric(horizontal: isPhone ? 10 : 22),
          child: Row(
            children: [
              Expanded(
                child: Text(left, style: st, overflow: TextOverflow.ellipsis),
              ),
              Text('${(fraction * 100).floor()}%', style: st),
              const SizedBox(width: 14),
              Text(_clockText(), style: st),
            ],
          ),
        ),
      ),
    );
  }

  /// The status line's height on a phone (kept clear of the text when asked).
  static const _statusH = 20.0;

  BoxDecoration get _barDeco => BoxDecoration(
    color: tk.panel.withValues(alpha: 0.96),
    border: Border.all(color: tk.line),
    borderRadius: BorderRadius.circular(lk.rPanel + 2),
    boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 18)],
  );

  Widget _topBar() {
    final ctls = _controls;
    Widget btn(int i) => _LabelBtn(ctls[i], focused: menu && menuIndex == i, onTap: () => _tapCtl(i), compact: isPhone);
    if (isPhone) {
      // A phone: right at the top (just under the camera), compact. Folded,
      // it shows back plus four controls, and "More" for the rest.
      final wide = MediaQuery.sizeOf(context).width / Look.I.readerScale >= ctls.length * 60 + 40;
      final shown = wide ? ctls.length : (ctls.length < 5 ? ctls.length : 5);
      return Positioned(
        left: 4,
        right: 4,
        top: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(2, 2, 2, 2),
          decoration: _barDeco,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (var i = 0; i < shown; i++) btn(i),
                  if (shown < ctls.length)
                    _LabelBtn(
                      _Ctl(moreOpen ? Icons.expand_less : Icons.expand_more, moreOpen ? 'Less' : 'More', 'More controls', () {}),
                      focused: false,
                      compact: true,
                      onTap: () => setState(() => moreOpen = !moreOpen),
                    ),
                ],
              ),
              if (moreOpen || wide)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
                  child: Text(
                    chapter.isEmpty ? _title : '$_title · $chapter',
                    style: ts(size: 12, c: tk.sec),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (moreOpen && shown < ctls.length)
                Wrap(
                  alignment: WrapAlignment.start,
                  children: [for (var i = shown; i < ctls.length; i++) btn(i)],
                ),
            ],
          ),
        ),
      );
    }
    return Positioned(
      left: 10,
      right: 10,
      top: 10,
      child: _hoverZone(
        'top',
        LayoutBuilder(
          builder: (context, box) {
            // A narrow window: the title on one line, the controls on a
            // second line that scrolls sideways.
            if (box.maxWidth < ctls.length * 70 + 220) {
              return Container(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                decoration: _barDeco,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        btn(0),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_title, style: ts(w: FontWeight.w600), overflow: TextOverflow.ellipsis, maxLines: 2),
                              if (chapter.isNotEmpty) Text(chapter, style: ts(size: 11.5, c: tk.faint), overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                      ],
                    ),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: [for (var i = 1; i < ctls.length; i++) btn(i)]),
                    ),
                  ],
                ),
              );
            }
            return Container(
              height: 60,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: _barDeco,
              child: Row(
                children: [
                  btn(0),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_title, style: ts(w: FontWeight.w600), overflow: TextOverflow.ellipsis),
                        if (chapter.isNotEmpty && !menu) Text(chapter, style: ts(size: 11.5, c: tk.faint), overflow: TextOverflow.ellipsis),
                        if (menu)
                          Text(
                            '← → move · Enter or Space choose · M or Esc close',
                            style: ts(size: 11, c: lk.acc),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  for (var i = 1; i < ctls.length; i++) btn(i),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  bool get _narrow => MediaQuery.sizeOf(context).width / Look.I.readerScale < 560;

  void _tapCtl(int i) {
    final c = _controls[i];
    if (menu) {
      menuIndex = i;
      if (c.closes) closeMenu(rebuild: false);
    }
    c.onTap();
    setState(() {});
  }

  Widget _bottomBar() {
    final left = minSection == null
        ? (minTotal == null ? '' : '${_mins(minTotal)} left in the book')
        : '${_mins(minSection)} left in the chapter · ${_mins(minTotal)} left in the book';
    return Positioned(
      left: isPhone ? 4 : 10,
      right: isPhone ? 4 : 10,
      bottom: isPhone ? 4 : 10,
      child: _hoverZone(
        'bottom',
        Container(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
          decoration: _barDeco,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text('${(fraction * 100).floor()}%', style: ts(w: FontWeight.w700, tab: true)),
                  const SizedBox(width: 10),
                  Expanded(
                    // Tap to see all of it (a folded phone shows only a little).
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => bottomOpen = !bottomOpen),
                      child: Text(
                        [
                          if (isPdf && pages > 0) pageLast > page ? 'Pages $page–$pageLast of $pages' : 'Page $page of $pages',
                          if (!isPdf && pages > 0) 'Page $page of $pages in this chapter',
                          left,
                        ].where((x) => x.isNotEmpty).join(bottomOpen ? '\n' : ' · '),
                        style: ts(c: tk.sec, size: 12, tab: true),
                        overflow: bottomOpen ? null : TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (nextVol != null) Btn.ghost('Next volume', icon: Icons.skip_next_outlined, dense: true, onTap: openNext),
                ],
              ),
              const SizedBox(height: 6),
              _ProgressSlider(value: fraction, onChanged: goFraction),
            ],
          ),
        ),
      ),
    );
  }

  Widget _panel() {
    final Widget body = switch (panel) {
      'contents' => _contents(),
      'bookmarks' => _bookmarks(),
      'search' => _search(),
      'text' => _textPanel(),
      _ => _styles(),
    };
    final title = switch (panel) {
      'contents' => 'Contents',
      'bookmarks' => 'Bookmarks',
      'search' => 'Search in the book',
      'text' => 'Text & spacing',
      _ => 'Settings',
    };
    if (isPhone) {
      // A phone: just this panel (the bars hide), along the top right, 60% of
      // the screen each way; it scrolls inside. A tap outside closes it.
      final sz = MediaQuery.sizeOf(context);
      return Positioned.fill(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => panel = null),
              ),
            ),
            Positioned(
              right: 4,
              top: 0,
              width: (sz.width * 0.6).clamp(240.0, sz.width - 8),
              height: (sz.height * 0.6).clamp(260.0, sz.height - 8),
              child: _panelBox(title, body),
            ),
          ],
        ),
      );
    }
    return Positioned(
      right: 10,
      top: chrome ? (_narrow ? 130 : 78) : 10,
      bottom: chrome ? 96 : 10,
      left: _narrow ? 10 : null,
      width: _narrow ? null : 400,
      child: _hoverZone('panel', _panelBox(title, body)),
    );
  }

  Widget _panelBox(String title, Widget body) => Container(
    decoration: _barDeco,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(14, isPhone ? 4 : 10, 6, isPhone ? 2 : 6),
          child: Row(
            children: [
              Expanded(child: Text(title, style: ts(w: FontWeight.w700))),
              IconBtn(Icons.close, tooltip: 'Close (Esc)', onTap: () => setState(() => panel = null)),
            ],
          ),
        ),
        Expanded(child: body),
      ],
    ),
  );

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
              child: Text(
                it.label.isEmpty ? 'Untitled' : it.label,
                style: ts(c: on ? tk.text : tk.sec, w: on ? FontWeight.w600 : null),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _bookmarks() {
    final bms = Db.I.bookmarks(book.id);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(
            children: [Btn('Bookmark this page', icon: Icons.bookmark_add_outlined, onTap: addBookmark)],
          ),
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
                            decoration: BoxDecoration(
                              color: h ? tk.raised : null,
                              borderRadius: BorderRadius.circular(lk.rControl),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.bookmark, size: 16, color: lk.acc),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(b.label, style: ts(), overflow: TextOverflow.ellipsis),
                                      Text(dateText(b.at), style: ts(size: 11.5, c: tk.faint)),
                                    ],
                                  ),
                                ),
                                IconBtn(
                                  Icons.close,
                                  tooltip: 'Remove this bookmark',
                                  onTap: () {
                                    Db.I.deleteBookmark(b.id);
                                    setState(() {});
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  void _runSearch(String q) {
    setState(() {
      searching = q.trim().isNotEmpty;
      results = [];
    });
    cmd('sable.search(${jsonEncode(q.trim())})');
  }

  /// The search box takes keys from the book page too: when the book still
  /// has the keyboard (Windows can keep it there after a click on the page),
  /// what's typed arrives here.
  bool _typingSent = false;
  void _syncTyping() {
    final want = panel == 'search' && !isPdf;
    if (want == _typingSent) return;
    _typingSent = want;
    cmd('sable.setTyping($want)');
  }

  void _typeKey(String key, bool ctrl) {
    final t = searchCtl.text;
    switch (key) {
      case 'Escape':
        setState(() => panel = null);
      case 'Enter':
        _runSearch(t);
      case 'Backspace':
        if (t.isNotEmpty) searchCtl.text = t.substring(0, t.length - 1);
      default:
        if (key.length == 1 && !ctrl) searchCtl.text = t + key;
    }
    searchCtl.selection = TextSelection.collapsed(offset: searchCtl.text.length);
    setState(() {});
  }

  Widget _search() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Field(
            controller: searchCtl,
            autofocus: true,
            hint: 'Words to find, then Enter',
            icon: Icons.search,
            onSubmitted: _runSearch,
          ),
        ),
        if (searching)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const SizedBox(width: 60, child: Progress(value: null, height: 4)),
                const SizedBox(width: 8),
                Text('Searching…', style: ts(c: tk.faint, size: 12)),
              ],
            ),
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if ('${r['label']}'.isNotEmpty) Text('${r['label']}', style: ts(size: 11.5, c: tk.faint)),
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '${r['pre']}',
                                style: ts(c: tk.sec),
                              ),
                              TextSpan(
                                text: '${r['match']}',
                                style: ts(c: lk.acc, w: FontWeight.w700),
                              ),
                              TextSpan(
                                text: '${r['post']}',
                                style: ts(c: tk.sec),
                              ),
                            ],
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// A setting's row: the name, the control, and a reset button once it's changed.
  /// In a narrow panel (a phone) the name sits above the control.
  Widget _row(String label, Widget child, {bool changed = false, VoidCallback? reset}) {
    final resetBtn = SizedBox(
      width: lk.hControl,
      child: changed && reset != null ? IconBtn(Icons.restart_alt, tooltip: 'Back to the default', onTap: reset) : null,
    );
    if (_narrowPanel) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: ts(c: tk.sec, size: 12.5)),
            const SizedBox(height: 3),
            Row(
              children: [
                Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: child)),
                resetBtn,
              ],
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(width: 118, child: Text(label, style: ts(c: tk.sec))),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
          resetBtn,
        ],
      ),
    );
  }

  bool get _narrowPanel => isPhone || _narrow;

  Widget _sw(bool v, ValueChanged<bool> f) => Switch(value: v, onChanged: f);

  void _set(void Function() f) {
    f();
    _styleChanged();
  }

  /// Reader settings: how pages look and behave (the text itself is in "Text & spacing").
  Widget _styles() {
    final s = Settings.I.style;
    final d = Settings.defaults.style;
    final set = _set;
    final row = _row;
    final sw = _sw;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 0, 8, 14),
      children: [
        row(
          'Theme',
          Seg<String>(
            value: Look.I.theme,
            items: const [('OLED black', 'OLED black'), ('Starlight', 'Starlight')],
            onChanged: (v) {
              Look.I.setTheme(v);
              _themeChanged();
            },
          ),
          changed: Look.I.theme != 'OLED black',
          reset: () {
            Look.I.setTheme('OLED black');
            _themeChanged();
          },
        ),
        row(
          'Pages',
          Seg<PageLayout>(
            value: s.layout,
            items: const [(PageLayout.auto, 'Auto'), (PageLayout.one, 'One'), (PageLayout.two, 'Two')],
            onChanged: (v) => set(() => s.layout = v),
          ),
          changed: s.layout != d.layout,
          reset: () => set(() => s.layout = d.layout),
        ),
        if (isPdf) ...[
          row(
            'Crop borders',
            sw(Settings.I.pdfCrop, (v) {
              Settings.I.pdfCrop = v;
              Settings.I.save();
              setState(() {});
            }),
            changed: Settings.I.pdfCrop,
            reset: () {
              Settings.I.pdfCrop = false;
              Settings.I.save();
              setState(() {});
            },
          ),
          row(
            'Dark pages',
            sw(Settings.I.pdfDarkPages, (v) {
              Settings.I.pdfDarkPages = v;
              Settings.I.save();
              setState(() {});
            }),
            changed: Settings.I.pdfDarkPages,
            reset: () {
              Settings.I.pdfDarkPages = false;
              Settings.I.save();
              setState(() {});
            },
          ),
        ],
        if (!isPdf) ...[
          row(
            'Text colour',
            _ColourSwatch(
              colour: s.textColor.isEmpty ? tk.pageFg : parseHex(s.textColor),
              label: s.textColor.isEmpty ? 'Theme' : s.textColor.toUpperCase(),
              onTap: () async {
                final start = s.textColor.isEmpty ? null : parseHex(s.textColor);
                final c = await pickColour(context, start ?? Colors.white, 'Text colour');
                if (c != null) set(() => s.textColor = hexOf(c));
              },
            ),
            changed: s.textColor != d.textColor,
            reset: () => set(() => s.textColor = d.textColor),
          ),
          row(
            'Alignment',
            Seg<String>(
              value: s.align,
              items: const [('left', 'Left'), ('center', 'Middle'), ('right', 'Right'), ('justify', 'Justify')],
              onChanged: (v) => set(() => s.align = v),
            ),
            changed: s.align != d.align,
            reset: () => set(() => s.align = d.align),
          ),
          row(
            'Same top line',
            sw(s.alignTop, (v) => set(() => s.alignTop = v)),
            changed: s.alignTop != d.alignTop,
            reset: () => set(() => s.alignTop = d.alignTop),
          ),
          if (_narrowPanel)
            Text('Every page starts on the same line, even at a new chapter or a heading.', style: ts(size: 11.5, c: tk.faint))
          else
            Padding(
              padding: const EdgeInsets.only(left: 118, bottom: 4),
              child: Text('Every page starts on the same line, even at a new chapter or a heading.', style: ts(size: 11.5, c: tk.faint)),
            ),
          row(
            'Turning',
            Seg<PageFlow>(
              value: s.flow,
              items: const [(PageFlow.paged, 'Pages'), (PageFlow.scrolled, 'Scroll')],
              onChanged: (v) => set(() => s.flow = v),
            ),
            changed: s.flow != d.flow,
            reset: () => set(() => s.flow = d.flow),
          ),
          if (s.flow == PageFlow.scrolled && !isPhone)
            row(
              'Scroll distance',
              NumStep(
                value: s.scrollStep,
                step: 10,
                min: 40,
                max: 600,
                title: 'Scroll distance (px a notch)',
                format: (v) => '${v.round()} px',
                onChanged: (v) => set(() => s.scrollStep = v),
              ),
              changed: s.scrollStep != d.scrollStep,
              reset: () => set(() => s.scrollStep = d.scrollStep),
            ),
          row(
            'Animation',
            sw(s.animate, (v) => set(() => s.animate = v)),
            changed: s.animate != d.animate,
            reset: () => set(() => s.animate = d.animate),
          ),
        ],
        if (isPhone) ...[
          row(
            'Clear of the notch',
            sw(s.clearNotch, (v) => set(() => s.clearNotch = v)),
            changed: s.clearNotch != d.clearNotch,
            reset: () => set(() => s.clearNotch = d.clearNotch),
          ),
          row(
            'Clear of the status line',
            sw(s.clearStatus, (v) => set(() => s.clearStatus = v)),
            changed: s.clearStatus != d.clearStatus,
            reset: () => set(() => s.clearStatus = d.clearStatus),
          ),
        ],
        row(
          'Controls size',
          NumStep(
            value: (Look.I.readerScale * 100).roundToDouble(),
            step: 5,
            min: 60,
            max: 200,
            title: 'Controls size (%)',
            format: (v) => '${v.round()}%',
            onChanged: (v) {
              Look.I.readerScale = v / 100;
              Look.I.save();
              setState(() {});
            },
          ),
          changed: (Look.I.readerScale - Look.defaultReaderScale).abs() > 0.001,
          reset: () {
            Look.I.readerScale = Look.defaultReaderScale;
            Look.I.save();
            setState(() {});
          },
        ),
        if (!isPhone)
          row(
            'Mouse ◀ ▶',
            Seg<String>(
              value: Settings.I.mouseInReader,
              items: const [('pages', 'Turn pages'), ('leave', 'Back leaves')],
              onChanged: (v) {
                Settings.I.mouseInReader = v;
                Settings.I.save();
                setState(() {});
              },
            ),
            changed: Settings.I.mouseInReader != 'pages',
            reset: () {
              Settings.I.mouseInReader = 'pages';
              Settings.I.save();
              setState(() {});
            },
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: Text('These apply to every book.', style: ts(size: 11.5, c: tk.faint))),
            Btn.ghost(
              'Reset all',
              icon: Icons.restart_alt,
              dense: true,
              onTap: () {
                final keep = ReadingStyle()..apply(s.toJson());
                s.apply(ReadingStyle().toJson());
                // The text and spacing settings have their own reset.
                s
                  ..font = keep.font
                  ..size = keep.size
                  ..spacing = keep.spacing
                  ..wordSpacing = keep.wordSpacing
                  ..paraSpacing = keep.paraSpacing
                  ..indent = keep.indent
                  ..marginXPct = keep.marginXPct
                  ..marginYPct = keep.marginYPct
                  ..publisherStyles = keep.publisherStyles;
                Settings.I.pdfDarkPages = false;
                Settings.I.pdfCrop = false;
                Settings.I.mouseInReader = 'pages';
                Look.I.readerScale = Look.defaultReaderScale;
                Look.I.save();
                _styleChanged();
              },
            ),
          ],
        ),
      ],
    );
  }

  /// Text & spacing: the font, sizes, spacing and margins.
  Widget _textPanel() {
    final s = Settings.I.style;
    final d = Settings.defaults.style;
    final set = _set;
    final row = _row;
    if (isPdf) {
      return EmptyState(icon: Icons.format_size, text: 'A PDF\'s text is fixed by the PDF itself.');
    }
    String pct(double v) => '${v == v.roundToDouble() ? v.round() : v.toStringAsFixed(1)}%';
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 0, 8, 14),
      children: [
        row(
          'Font',
          Drop<String>(
            value: s.font,
            width: _narrowPanel ? 180 : 200,
            items: [for (final f in readingFonts) (f, fontLabel(f))],
            onChanged: (v) => set(() => s.font = v),
          ),
          changed: s.font != d.font,
          reset: () => set(() => s.font = d.font),
        ),
        row(
          'Text size',
          NumStep(
            value: s.size,
            step: 0.5,
            min: 10,
            max: 48,
            title: 'Text size',
            onChanged: (v) => set(() => s.size = v),
          ),
          changed: s.size != d.size,
          reset: () => set(() => s.size = d.size),
        ),
        row(
          'Line spacing',
          NumStep(
            value: s.spacing,
            step: 0.05,
            min: 0.8,
            max: 3,
            title: 'Line spacing',
            format: (v) => v.toStringAsFixed(2),
            onChanged: (v) => set(() => s.spacing = v),
          ),
          changed: s.spacing != d.spacing,
          reset: () => set(() => s.spacing = d.spacing),
        ),
        row(
          'Word spacing',
          NumStep(
            value: s.wordSpacing,
            step: 0.5,
            min: -2,
            max: 20,
            title: 'Extra space between words (px)',
            onChanged: (v) => set(() => s.wordSpacing = v),
          ),
          changed: s.wordSpacing != d.wordSpacing,
          reset: () => set(() => s.wordSpacing = d.wordSpacing),
        ),
        row(
          'Paragraph spacing',
          NumStep(
            value: s.paraSpacing,
            step: 0.05,
            min: 0,
            max: 3,
            title: 'Space after each paragraph (lines)',
            format: (v) => v.toStringAsFixed(2),
            onChanged: (v) => set(() => s.paraSpacing = v),
          ),
          changed: s.paraSpacing != d.paraSpacing,
          reset: () => set(() => s.paraSpacing = d.paraSpacing),
        ),
        row(
          'Indent paragraphs',
          _sw(s.indent, (v) => set(() => s.indent = v)),
          changed: s.indent != d.indent,
          reset: () => set(() => s.indent = d.indent),
        ),
        row(
          'Side margins',
          NumStep(
            value: s.marginXPct,
            step: 0.5,
            min: 0,
            max: 30,
            title: 'Side margins (% of the width)',
            format: pct,
            onChanged: (v) => set(() => s.marginXPct = v),
          ),
          changed: s.marginXPct != d.marginXPct,
          reset: () => set(() => s.marginXPct = d.marginXPct),
        ),
        row(
          'Top & bottom margins',
          NumStep(
            value: s.marginYPct,
            step: 0.5,
            min: 0,
            max: 30,
            title: 'Top and bottom margins (% of the height)',
            format: pct,
            onChanged: (v) => set(() => s.marginYPct = v),
          ),
          changed: s.marginYPct != d.marginYPct,
          reset: () => set(() => s.marginYPct = d.marginYPct),
        ),
        row(
          'Book\'s own styles',
          _sw(s.publisherStyles, (v) => set(() => s.publisherStyles = v)),
          changed: s.publisherStyles != d.publisherStyles,
          reset: () => set(() => s.publisherStyles = d.publisherStyles),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: Text('Hold − or + to keep going; tap a number to type it.', style: ts(size: 11.5, c: tk.faint))),
            Btn.ghost(
              'Reset',
              icon: Icons.restart_alt,
              dense: true,
              onTap: () => set(() {
                s
                  ..font = d.font
                  ..size = d.size
                  ..spacing = d.spacing
                  ..wordSpacing = d.wordSpacing
                  ..paraSpacing = d.paraSpacing
                  ..indent = d.indent
                  ..marginXPct = d.marginXPct
                  ..marginYPct = d.marginYPct
                  ..publisherStyles = d.publisherStyles;
              }),
            ),
          ],
        ),
      ],
    );
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(gradient: lk.grad, shape: BoxShape.circle),
                    child: Icon(Icons.check, color: lk.onAcc),
                  ),
                  const SizedBox(height: 12),
                  Text('Finished', style: ts(size: 16, w: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    _title,
                    style: ts(c: tk.sec),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 14),
                  if (v != null) ...[
                    Stars(
                      value: v.rating,
                      size: 26,
                      onChanged: (r) {
                        Library.I.setRating(v, r);
                        setState(() {});
                      },
                    ),
                    const SizedBox(height: 10),
                    Btn.ghost(
                      v.favourite ? 'Favourite' : 'Add to favourites',
                      icon: v.favourite ? Icons.favorite : Icons.favorite_border,
                      onTap: toggleFavourite,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Btn('Back to the library', onTap: () => Navigator.of(context).maybePop()),
                      if (n != null) ...[
                        const SizedBox(width: 8),
                        Btn.primary(
                          'Next: ${n.any.volumeText.isEmpty ? n.any.displayTitle : n.any.volumeText}',
                          icon: Icons.skip_next,
                          onTap: openNext,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
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

/// One of the reader's controls.
class _Ctl {
  _Ctl(this.icon, this.label, this.tooltip, this.onTap, {this.active = false, this.color, this.closes = false});
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final Color? color;

  /// Opening this closes the keyboard menu (it opens a panel or leaves).
  final bool closes;
}

/// An icon with its name under it; outlined when the keyboard menu is on it.
class _LabelBtn extends StatelessWidget {
  const _LabelBtn(this.c, {required this.focused, required this.onTap, this.compact = false});
  final _Ctl c;
  final bool focused;
  final VoidCallback onTap;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: c.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: Hoverable(
        builder: (h) => GestureDetector(
          onTap: onTap,
          child: Container(
            width: compact ? 58 : 68,
            height: compact ? 44 : 50,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: c.active ? lk.tint(tk.raised, 0.22) : (h || focused ? tk.raised : null),
              borderRadius: BorderRadius.circular(lk.rControl),
              border: Border.all(color: focused ? lk.acc : Colors.transparent, width: 1.5),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(c.icon, size: compact ? 19 : 20, color: c.color ?? (c.active || focused ? tk.text : tk.sec)),
                const SizedBox(height: 3),
                Text(
                  c.label,
                  style: ts(size: compact ? 10 : 10.5, c: c.active || focused ? tk.text : tk.faint),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small colour sample with its name, that opens a colour picker.
class _ColourSwatch extends StatelessWidget {
  const _ColourSwatch({required this.colour, required this.label, required this.onTap});
  final Color colour;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Hoverable(
      builder: (h) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: lk.hControl,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: h ? tk.raised : tk.field,
            border: Border.all(color: tk.line),
            borderRadius: BorderRadius.circular(lk.rControl),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: colour,
                  shape: BoxShape.circle,
                  border: Border.all(color: tk.line),
                ),
              ),
              const SizedBox(width: 8),
              Text(label, style: ts(tab: true)),
            ],
          ),
        ),
      ),
    );
  }
}

Color parseHex(String s) => Color(int.parse('ff${s.substring(1)}', radix: 16));
String hexOf(Color c) => '#${(c.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
