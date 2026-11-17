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
  String font = 'Literata'; // book | Literata | Inter | Georgia | Palatino Linotype
  double size = 18; // px
  double spacing = 1.5;
  double marginX = 96; // px at the left and right of the text (and between two pages)
  double marginY = 44; // px at the top and bottom

  /// Text colour on the page as #rrggbb, or '' for the theme's own.
  String textColor = '';
  bool justify = true;
  bool publisherStyles = false;
  PageLayout layout = PageLayout.auto;
  PageFlow flow = PageFlow.paged;
  bool animate = true;

  /// Scroll mode: how far one notch of the mouse wheel moves (px).
  double scrollStep = 140;

  Map<String, dynamic> toJson() => {
    'font': font,
    'size': size,
    'spacing': spacing,
    'marginX': marginX,
    'marginY': marginY,
    'textColor': textColor,
    'justify': justify,
    'publisherStyles': publisherStyles,
    'layout': layout.name,
    'flow': flow.name,
    'animate': animate,
    'scrollStep': scrollStep,
  };

  void apply(Map m) {
    font = m['font'] as String? ?? font;
    if (!readingFonts.contains(font)) font = 'Literata';
    size = ((m['size'] as num?)?.toDouble() ?? size).clamp(12, 36);
    spacing = ((m['spacing'] as num?)?.toDouble() ?? spacing).clamp(1.0, 2.4);
    // Before 1.2, one 'margin' setting was half the space at the sides.
    final old = (m['margin'] as num?)?.toDouble();
    marginX = ((m['marginX'] as num?)?.toDouble() ?? (old == null ? null : old * 2) ?? marginX).clamp(0, 320);
    marginY = ((m['marginY'] as num?)?.toDouble() ?? marginY).clamp(0, 200);
    final tc = m['textColor'];
    textColor = tc is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(tc) ? tc : (tc == '' ? '' : textColor);
    justify = m['justify'] as bool? ?? justify;
    publisherStyles = m['publisherStyles'] as bool? ?? publisherStyles;
    layout = PageLayout.values.firstWhere((e) => e.name == m['layout'], orElse: () => layout);
    flow = PageFlow.values.firstWhere((e) => e.name == m['flow'], orElse: () => flow);
    animate = m['animate'] as bool? ?? animate;
    scrollStep = ((m['scrollStep'] as num?)?.toDouble() ?? scrollStep).clamp(40, 600);
  }
}

const readingFonts = ['book', 'Literata', 'Inter', 'Georgia', 'Palatino Linotype'];

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
