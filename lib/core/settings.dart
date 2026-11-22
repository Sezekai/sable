import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'paths.dart';
import 'platform.dart';

/// Book or light novel. It's only a field: one library holds both.
enum Kind {
  book('Book'),
  ln('Light novel');

  const Kind(this.label);
  final String label;
  static Kind byName(String? n) => n == 'ln' ? Kind.ln : Kind.book;
}

/// A folder the library is built from.
class LibFolder {
  LibFolder(this.path, {this.kind = Kind.book, this.collection = false});
  String path;
  Kind kind;

  /// Books from downloaded packs; hidden all at once by "Show collections".
  bool collection;

  Map<String, dynamic> toJson() => {'path': path, 'kind': kind.name, 'collection': collection};
  static LibFolder fromJson(Map m) => LibFolder(
    m['path'] as String? ?? '',
    kind: Kind.byName(m['kind'] as String?),
    collection: m['collection'] as bool? ?? false,
  );
}

enum PageLayout { auto, one, two }

enum PageFlow { paged, scrolled }

/// Reading look. A few options, like Lithium.
class ReadingStyle {
  String font = 'Literata'; // see readingFonts
  double size = 18; // px, in steps of 0.5
  double spacing = 1.5; // line spacing
  double wordSpacing = 0; // extra px between words
  double paraSpacing = 0.5; // space after each paragraph, in lines (em)

  /// Margins as a share of the window (%): left and right (and between two
  /// pages), and top and bottom.
  double marginXPct = 6;
  double marginYPct = 5;

  /// Text colour on the page as #rrggbb, or '' for the theme's own.
  String textColor = '';

  /// left | center | right | justify
  String align = 'justify';

  /// Start each paragraph indented.
  bool indent = false;

  /// Every page starts on the same line (nothing pushes the text down).
  bool alignTop = false;

  bool publisherStyles = false;
  PageLayout layout = PageLayout.auto;
  PageFlow flow = PageFlow.paged;
  bool animate = true;

  /// Phone: keep the text clear of the camera notch, and of the status line.
  bool clearNotch = true;
  bool clearStatus = true;

  /// Scroll mode: how far one notch of the mouse wheel moves (px).
  double scrollStep = 140;

  bool get justify => align == 'justify';

  Map<String, dynamic> toJson() => {
    'font': font,
    'size': size,
    'spacing': spacing,
    'wordSpacing': wordSpacing,
    'paraSpacing': paraSpacing,
    'marginXPct': marginXPct,
    'marginYPct': marginYPct,
    'textColor': textColor,
    'align': align,
    'indent': indent,
    'alignTop': alignTop,
    'publisherStyles': publisherStyles,
    'layout': layout.name,
    'flow': flow.name,
    'animate': animate,
    'clearNotch': clearNotch,
    'clearStatus': clearStatus,
    'scrollStep': scrollStep,
  };

  static double _half(num v) => (v * 2).round() / 2;
  static double _d(Object? v) => (v as num?)?.toDouble() ?? double.nan;

  void apply(Map m) {
    font = m['font'] as String? ?? font;
    if (!readingFonts.contains(font)) font = 'Literata';
    double pick(String k, double cur) {
      final v = _d(m[k]);
      return v.isNaN ? cur : v;
    }

    size = _half(pick('size', size).clamp(10, 48));
    spacing = (pick('spacing', spacing).clamp(0.8, 3.0) * 20).round() / 20;
    wordSpacing = _half(pick('wordSpacing', wordSpacing).clamp(-2, 20));
    paraSpacing = (pick('paraSpacing', paraSpacing).clamp(0, 3) * 20).round() / 20;
    // Before 1.4 the margins were in px (and before 1.2 one 'margin' was half the sides).
    final oldX = _d(m['marginX']), oldM = _d(m['margin']), oldY = _d(m['marginY']);
    if (!m.containsKey('marginXPct') && (!oldX.isNaN || !oldM.isNaN)) {
      marginXPct = _half(((oldX.isNaN ? oldM * 2 : oldX) / 14).clamp(0, 30));
    }
    if (!m.containsKey('marginYPct') && !oldY.isNaN) marginYPct = _half((oldY / 8.5).clamp(0, 30));
    marginXPct = _half(pick('marginXPct', marginXPct).clamp(0, 30));
    marginYPct = _half(pick('marginYPct', marginYPct).clamp(0, 30));
    final tc = m['textColor'];
    textColor = tc is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(tc) ? tc : (tc == '' ? '' : textColor);
    final al = m['align'];
    if (al is String && const ['left', 'center', 'right', 'justify'].contains(al)) {
      align = al;
    } else if (m['justify'] is bool) {
      align = m['justify'] == true ? 'justify' : 'left';
    }
    indent = m['indent'] as bool? ?? indent;
    alignTop = m['alignTop'] as bool? ?? alignTop;
    publisherStyles = m['publisherStyles'] as bool? ?? publisherStyles;
    layout = PageLayout.values.firstWhere((e) => e.name == m['layout'], orElse: () => layout);
    flow = PageFlow.values.firstWhere((e) => e.name == m['flow'], orElse: () => flow);
    animate = m['animate'] as bool? ?? animate;
    clearNotch = m['clearNotch'] as bool? ?? clearNotch;
    clearStatus = m['clearStatus'] as bool? ?? clearStatus;
    scrollStep = ((m['scrollStep'] as num?)?.toDouble() ?? scrollStep).clamp(40, 600);
  }
}

const readingFonts = [
  'book',
  'Literata',
  'PT Serif',
  'Domine',
  'Arbutus Slab',
  'Georgia',
  'Palatino Linotype',
  'Inter',
  'Segoe UI',
  'Open Sans',
  'Lato',
];

String fontLabel(String f) => f == 'book' ? "The book's own" : f;

List<LibFolder> defaultFolders() => [
  LibFolder(r'E:\Documents\LIGHT NOVELS', kind: Kind.ln),
  LibFolder(r'E:\Documents\BOOKS'),
  LibFolder(r'E:\Documents\BOOKS I OWN'),
  LibFolder(r'E:\Documents\BOOK Collections', collection: true),
];

class Settings extends ChangeNotifier {
  Settings._();
  static final Settings I = Settings._();

  /// A copy with every setting at its default, to compare with and reset to.
  static final Settings defaults = Settings._();

  List<LibFolder> folders = defaultFolders();
  bool showCollections = true;
  final ReadingStyle style = ReadingStyle();
  int idleMinutes = 3;
  bool watchFolders = true;
  bool progressLine = true;
  bool skipRead = false;
  bool pdfDarkPages = false;

  /// PDFs: trim plain white or black borders around each page.
  bool pdfCrop = false;

  /// What the mouse's back and forward buttons do in the reader: 'pages' or 'leave'.
  String mouseInReader = 'pages';

  /// Passwords tried on locked ZIPs (as well as any "password" .txt file in a library folder).
  List<String> zipPasswords = [];

  // Library view
  String gridStyle = 'comfortable'; // comfortable | compact | cover
  double tileSize = isPhone ? 112 : 168;
  bool listView = false;
  String sort = 'lastRead';
  bool sortDesc = true;
  bool showContinue = true;
  Map<String, String> presets = {};

  Map<String, dynamic> windowState = {};

  void load() {
    try {
      final f = File(AppPaths.I.settingsFile);
      if (!f.existsSync()) return;
      final m = jsonDecode(f.readAsStringSync()) as Map;
      final fl = m['folders'];
      if (fl is List) folders = fl.whereType<Map>().map(LibFolder.fromJson).where((x) => x.path.isNotEmpty).toList();
      showCollections = m['showCollections'] as bool? ?? true;
      if (m['style'] is Map) style.apply(m['style'] as Map);
      idleMinutes = ((m['idleMinutes'] as num?)?.toInt() ?? 3).clamp(1, 30);
      watchFolders = m['watchFolders'] as bool? ?? true;
      progressLine = m['progressLine'] as bool? ?? true;
      skipRead = m['skipRead'] as bool? ?? false;
      pdfDarkPages = m['pdfDarkPages'] as bool? ?? false;
      pdfCrop = m['pdfCrop'] as bool? ?? false;
      mouseInReader = m['mouseInReader'] == 'leave' ? 'leave' : 'pages';
      zipPasswords = ((m['zipPasswords'] as List?) ?? []).whereType<String>().toList();
      gridStyle = m['gridStyle'] as String? ?? gridStyle;
      tileSize = ((m['tileSize'] as num?)?.toDouble() ?? tileSize).clamp(isPhone ? 80 : 110, 300);
      listView = m['listView'] as bool? ?? false;
      sort = m['sort'] as String? ?? sort;
      sortDesc = m['sortDesc'] as bool? ?? sortDesc;
      showContinue = m['showContinue'] as bool? ?? true;
      presets = (m['presets'] as Map?)?.cast<String, String>() ?? {};
      windowState = (m['window'] as Map?)?.cast<String, dynamic>() ?? {};
    } catch (_) {}
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'folders': folders.map((f) => f.toJson()).toList(),
    'showCollections': showCollections,
    'style': style.toJson(),
    'idleMinutes': idleMinutes,
    'watchFolders': watchFolders,
    'progressLine': progressLine,
    'skipRead': skipRead,
    'pdfDarkPages': pdfDarkPages,
    'pdfCrop': pdfCrop,
    'mouseInReader': mouseInReader,
    'zipPasswords': zipPasswords,
    'gridStyle': gridStyle,
    'tileSize': tileSize,
    'listView': listView,
    'sort': sort,
    'sortDesc': sortDesc,
    'showContinue': showContinue,
    'presets': presets,
    'window': windowState,
  };

  /// Changes apply straight away; there's no Save button.
  void save() {
    try {
      writeStringSafelySync(AppPaths.I.settingsFile, const JsonEncoder.withIndent('  ').convert(toJson()));
    } catch (_) {}
    notifyListeners();
  }

  LibFolder? folderFor(String path) {
    LibFolder? best;
    for (final f in folders) {
      final root = f.path.endsWith(r'\') || f.path.endsWith('/') ? f.path : '${f.path}${Platform.pathSeparator}';
      if (path.toLowerCase().startsWith(root.toLowerCase()) && (best == null || f.path.length > best.path.length)) {
        best = f;
      }
    }
    return best;
  }

  void resetToDefaults() {
    folders = defaultFolders();
    showCollections = true;
    style.apply(ReadingStyle().toJson());
    idleMinutes = 3;
    watchFolders = true;
    progressLine = true;
    skipRead = false;
    pdfDarkPages = false;
    pdfCrop = false;
    mouseInReader = 'pages';
    gridStyle = 'comfortable';
    tileSize = isPhone ? 112 : 168;
    listView = false;
    sort = 'lastRead';
    sortDesc = true;
    showContinue = true;
    save();
  }
}
