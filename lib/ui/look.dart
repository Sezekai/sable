import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/paths.dart';

/// Colour tokens. Every colour on screen comes from here.
class Tokens {
  final Color ground, rail, panel, raised, raised2, field, line, line2, text, sec, faint, stage;
  final Color ok, warn, danger;

  /// The reading page.
  final Color pageBg, pageFg, pageMuted;
  const Tokens({
    required this.ground,
    required this.rail,
    required this.panel,
    required this.raised,
    required this.raised2,
    required this.field,
    required this.line,
    required this.line2,
    required this.text,
    required this.sec,
    required this.faint,
    required this.stage,
    required this.pageBg,
    required this.pageFg,
    required this.pageMuted,
    this.ok = const Color(0xFF52D39A),
    this.warn = const Color(0xFFF2B64C),
    this.danger = const Color(0xFFF0616D),
  });

  Map<String, Color> toMap() => {
        'ground': ground,
        'rail': rail,
        'panel': panel,
        'raised': raised,
        'raised2': raised2,
        'field': field,
        'line': line,
        'line2': line2,
        'text': text,
        'sec': sec,
        'faint': faint,
        'pageBg': pageBg,
        'pageFg': pageFg,
        'pageMuted': pageMuted,
      };

  /// These colours with some replaced (the user's edits to a theme).
  Tokens withOverrides(Map<String, String> o) {
    if (o.isEmpty) return this;
    Color c(String k, Color d) => o[k] == null ? d : hexColor(o[k]!);
    return Tokens(
      ground: c('ground', ground),
      rail: c('rail', rail),
      panel: c('panel', panel),
      raised: c('raised', raised),
      raised2: c('raised2', raised2),
      field: c('field', field),
      line: c('line', line),
      line2: c('line2', line2),
      text: c('text', text),
      sec: c('sec', sec),
      faint: c('faint', faint),
      stage: c('ground', stage),
      pageBg: c('pageBg', pageBg),
      pageFg: c('pageFg', pageFg),
      pageMuted: c('pageMuted', pageMuted),
    );
  }
}

/// The colours a theme has, in the order the editor lists them.
const tokenLabels = <String, String>{
  'ground': 'Background',
  'rail': 'Sidebar',
  'panel': 'Panels and bars',
  'raised': 'Raised (buttons, chips)',
  'raised2': 'Hover',
  'field': 'Text boxes',
  'line': 'Lines',
  'line2': 'Strong lines',
  'text': 'Text',
  'sec': 'Secondary text',
  'faint': 'Faint text',
  'pageBg': 'Book page',
  'pageFg': 'Book text',
  'pageMuted': 'Book page details (status line)',
};

const defaultAccentFor = {'OLED black': 'Violet → Pink', 'Starlight': 'Silver → Violet'};

Color hexColor(String h) {
  var s = h.replaceAll('#', '').trim();
  if (s.length == 3) s = s.split('').map((c) => '$c$c').join();
  if (s.length != 6) return const Color(0xFFFF00FF);
  return Color(int.parse('FF$s', radix: 16));
}

String colorHex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// The two themes: OLED black and Starlight.
const themes = <String, Tokens>{
  'OLED black': Tokens(
    ground: Color(0xFF000000),
    rail: Color(0xFF000000),
    panel: Color(0xFF09090B),
    raised: Color(0xFF131316),
    raised2: Color(0xFF1C1C21),
    field: Color(0xFF050506),
    line: Color(0xFF19191D),
    line2: Color(0xFF29292F),
    text: Color(0xFFECECF0),
    sec: Color(0xFFA2A2AC),
    faint: Color(0xFF6D6D77),
    stage: Color(0xFF000000),
    pageBg: Color(0xFF000000),
    pageFg: Color(0xFFD8D8DE),
    pageMuted: Color(0xFF5E5E66),
  ),
  'Starlight': Tokens(
    ground: Color(0xFF05070F),
    rail: Color(0xFF03050B),
    panel: Color(0xFF0A0F1E),
    raised: Color(0xFF111930),
    raised2: Color(0xFF19233F),
    field: Color(0xFF040710),
    line: Color(0xFF162038),
    line2: Color(0xFF243150),
    text: Color(0xFFE8ECF8),
    sec: Color(0xFFA3ACC8),
    faint: Color(0xFF6E7898),
    stage: Color(0xFF03050B),
    pageBg: Color(0xFF060914),
    pageFg: Color(0xFFD5DBEC),
    pageMuted: Color(0xFF5A6482),
  ),
};

final Map<String, List<Color>> accentPresets = {
  'Violet → Pink': [hexColor('#9b6bff'), hexColor('#ff6fb1')],
  'Silver → Violet': [hexColor('#c9d4ff'), hexColor('#9b6bff')],
  'Violet → Blue': [hexColor('#9b6bff'), hexColor('#4f8dff')],
  'Aurora': [hexColor('#3ee0b0'), hexColor('#4fa8ff'), hexColor('#b07bff')],
  'Teal → Violet': [hexColor('#2fd6c0'), hexColor('#8b7bff')],
  'Mint → Sky': [hexColor('#6cf0b4'), hexColor('#6cc4ff')],
  'Sunset': [hexColor('#ff7a59'), hexColor('#ff4f8b'), hexColor('#9b6bff')],
  'Amber → Pink': [hexColor('#ffbf4a'), hexColor('#ff6fa8')],
};

/// The look: theme plus accent, kept in appearance.json.
class Look extends ChangeNotifier {
  Look._();
  static final Look I = Look._();

  String theme = 'OLED black';

  /// Per theme: the accent preset, or 'Custom' with its own colours.
  final Map<String, String> accents = {...defaultAccentFor};
  final Map<String, List<String>> customAccents = {};

  /// Per theme: colours the user changed (token -> #hex). Saved over the theme.
  final Map<String, Map<String, String>> overrides = {};

  /// How big the whole app is drawn (1 = 100%).
  double appScale = 1.0;

  /// How big the reader's bars, panels and status line are, on top of [appScale].
  double readerScale = 1.25;
  static const defaultAppScale = 1.0;
  static const defaultReaderScale = 1.25;

  String get accentName => accents[theme] ?? defaultAccentFor[theme] ?? 'Violet → Pink';

  // Fixed parts of the look, kept compact.
  final String font = 'Inter';
  final double fontSize = 13;
  final double rControl = 6;
  final double rPanel = 10;
  final double hControl = 30;
  final double hRow = 24;
  final String buttons = 'flat';
  final double outlineWidth = 2;

  Tokens baseTokens(String name) => themes[name] ?? themes['OLED black']!;
  Tokens get t => baseTokens(theme).withOverrides(overrides[theme] ?? const {});
  bool get starlight => theme == 'Starlight';
  List<Color> get accent {
    if (accentName == 'Custom') {
      final c = customAccents[theme];
      if (c != null && c.isNotEmpty) return c.map(hexColor).toList();
    }
    return accentPresets[accentName] ?? accentPresets['Violet → Pink']!;
  }

  bool themeEdited(String name) =>
      (overrides[name]?.isNotEmpty ?? false) || (accents[name] ?? defaultAccentFor[name]) != defaultAccentFor[name];
  Color get acc => accent.first;
  Color get outline => acc;
  Color get highlight => acc;

  Gradient get grad => LinearGradient(colors: accent.length == 1 ? [acc, acc] : accent);
  Gradient gradAt(double angle) {
    final rad = (angle - 90) * math.pi / 180;
    final dx = math.cos(rad), dy = math.sin(rad);
    return LinearGradient(begin: Alignment(-dx, -dy), end: Alignment(dx, dy), colors: accent);
  }

  Color get onAcc {
    final darkOk = accent.every((c) => contrast(c, const Color(0xFF0B0C0F)) >= 4.5);
    return darkOk ? const Color(0xFF0B0C0F) : Colors.white;
  }

  Color tint(Color surface, double amount) => Color.lerp(surface, highlight, amount)!;

  /// Colours for the book page, sent to the reader.
  Map<String, String> readerTheme() => {
        'bg': colorHex(t.pageBg),
        'fg': colorHex(t.pageFg),
        'muted': colorHex(t.pageMuted),
        'link': colorHex(Color.lerp(acc, Colors.white, 0.25)!),
        'accent': colorHex(acc),
      };

  void load() {
    try {
      final f = File(AppPaths.I.appearanceFile);
      if (!f.existsSync()) return;
      final m = jsonDecode(f.readAsStringSync()) as Map;
      final th = m['theme'] as String?;
      if (th != null && themes.containsKey(th)) theme = th;
      // Version 1 had one accent for both themes.
      final a = m['accent'] as String?;
      if (a != null && accentPresets.containsKey(a)) accents[theme] = a;
      final ac = m['accents'];
      if (ac is Map) {
        for (final e in ac.entries) {
          if (themes.containsKey(e.key) && (accentPresets.containsKey(e.value) || e.value == 'Custom')) {
            accents[e.key as String] = e.value as String;
          }
        }
      }
      final ca = m['customAccents'];
      if (ca is Map) {
        for (final e in ca.entries) {
          if (e.value is List) customAccents[e.key as String] = (e.value as List).cast<String>();
        }
      }
      final ov = m['overrides'];
      if (ov is Map) {
        for (final e in ov.entries) {
          if (e.value is Map) overrides[e.key as String] = (e.value as Map).cast<String, String>();
        }
      }
      appScale = ((m['appScale'] as num?)?.toDouble() ?? 1.0).clamp(0.8, 1.6);
      readerScale = ((m['readerScale'] as num?)?.toDouble() ?? defaultReaderScale).clamp(0.8, 2.0);
    } catch (_) {}
  }

  void save() {
    try {
      writeStringSafelySync(AppPaths.I.appearanceFile,
          const JsonEncoder.withIndent('  ').convert({
            'version': 2,
            'theme': theme,
            'accents': accents,
            'customAccents': customAccents,
            'overrides': overrides,
            'appScale': appScale,
            'readerScale': readerScale,
          }));
    } catch (_) {}
    notifyListeners();
  }

  void setTheme(String name) {
    theme = name;
    save();
  }

  void setAccent(String name) {
    accents[theme] = name;
    if (name == 'Custom' && (customAccents[theme]?.isEmpty ?? true)) {
      customAccents[theme] = accent.map(colorHex).toList();
    }
    save();
  }

  void setCustomAccent(int i, Color c) {
    final l = [...(customAccents[theme] ?? accent.map(colorHex).toList())];
    while (l.length <= i) {
      l.add(l.isEmpty ? '#9b6bff' : l.last);
    }
    l[i] = colorHex(c);
    customAccents[theme] = l;
    accents[theme] = 'Custom';
    save();
  }

  void setToken(String key, Color c) {
    final base = baseTokens(theme).toMap()[key];
    final m = overrides.putIfAbsent(theme, () => {});
    if (base != null && colorHex(base) == colorHex(c)) {
      m.remove(key);
    } else {
      m[key] = colorHex(c);
    }
    save();
  }

  void resetToken(String key) {
    overrides[theme]?.remove(key);
    save();
  }

  /// Puts one theme back as it came: colours and accent.
  void resetTheme(String name) {
    overrides.remove(name);
    customAccents.remove(name);
    accents[name] = defaultAccentFor[name] ?? 'Violet → Pink';
    save();
  }

  void resetToDefault() {
    theme = 'OLED black';
    overrides.clear();
    customAccents.clear();
    accents
      ..clear()
      ..addAll(defaultAccentFor);
    appScale = defaultAppScale;
    readerScale = defaultReaderScale;
    save();
  }

  ThemeData themeData() {
    const family = 'Inter';
    final base = ThemeData.dark();
    final text = base.textTheme.apply(fontFamily: family, bodyColor: t.text, displayColor: t.text);
    return base.copyWith(
      scaffoldBackgroundColor: t.ground,
      canvasColor: t.panel,
      colorScheme: const ColorScheme.dark().copyWith(
        primary: acc,
        onPrimary: onAcc,
        secondary: acc,
        surface: t.panel,
        onSurface: t.text,
        error: t.danger,
      ),
      textTheme: text.copyWith(
        bodyMedium: TextStyle(fontFamily: family, fontSize: fontSize, color: t.text),
        bodySmall: TextStyle(fontFamily: family, fontSize: fontSize - 1, color: t.sec),
        titleMedium: TextStyle(fontFamily: family, fontSize: fontSize + 2, fontWeight: FontWeight.w700, color: t.text),
        labelLarge: TextStyle(fontFamily: family, fontSize: fontSize, fontWeight: FontWeight.w600, color: t.text),
      ),
      dividerColor: t.line,
      focusColor: tint(t.panel, 0.2),
      hoverColor: t.raised2,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
            color: t.raised2, borderRadius: BorderRadius.circular(rControl), border: Border.all(color: t.line2)),
        textStyle: TextStyle(color: t.text, fontSize: fontSize - 1, fontFamily: family),
        waitDuration: const Duration(milliseconds: 500),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? acc : Colors.transparent),
        checkColor: WidgetStatePropertyAll(onAcc),
        side: BorderSide(color: t.line2, width: 1.5),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: acc,
        inactiveTrackColor: t.raised2,
        thumbColor: acc,
        overlayShape: SliderComponentShape.noOverlay,
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(t.line2),
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(4),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: t.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rPanel), side: BorderSide(color: t.line2)),
        textStyle: TextStyle(color: t.text, fontSize: fontSize, fontFamily: family),
      ),
      textSelectionTheme: TextSelectionThemeData(cursorColor: acc, selectionColor: tint(t.field, 0.35)),
    );
  }
}

double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// A faint, still star field for the Starlight theme.
class StarField extends StatelessWidget {
  const StarField({super.key});
  @override
  Widget build(BuildContext context) => IgnorePointer(child: RepaintBoundary(child: CustomPaint(painter: _StarPainter(Look.I.acc))));
}

class _StarPainter extends CustomPainter {
  _StarPainter(this.c);
  final Color c;
  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(7);
    // A soft glow in one corner, like a distant nebula.
    // A faint wash of the accent from the top right, like a distant glow.
    final glow = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.center,
        colors: [c.withValues(alpha: 0.10), c.withValues(alpha: 0.0)],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, glow);
    final n = (size.width * size.height / 5200).clamp(80, 700).toInt();
    final p = Paint();
    for (var i = 0; i < n; i++) {
      final x = rnd.nextDouble() * size.width, y = rnd.nextDouble() * size.height;
      final big = rnd.nextDouble() < 0.06;
      final a = 0.18 + rnd.nextDouble() * (big ? 0.6 : 0.35);
      p.color = Color.lerp(const Color(0xFFFFFFFF), const Color(0xFFB8C6FF), rnd.nextDouble())!.withValues(alpha: a);
      canvas.drawCircle(Offset(x, y), big ? 1.3 : 0.7, p);
    }
  }

  @override
  bool shouldRepaint(covariant _StarPainter oldDelegate) => oldDelegate.c != c;
}

/// Draws [child] bigger or smaller, as if the window were a different size.
/// Text stays sharp because it's drawn at the final size.
class UiScale extends StatelessWidget {
  const UiScale({super.key, required this.scale, required this.child});
  final double scale;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if ((scale - 1).abs() < 0.001) return child;
    return LayoutBuilder(builder: (context, box) {
      final mq = MediaQuery.of(context);
      final w = box.maxWidth / scale, h = box.maxHeight / scale;
      return Transform.scale(
        scale: scale,
        alignment: Alignment.topLeft,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: w,
          maxWidth: w,
          minHeight: h,
          maxHeight: h,
          child: MediaQuery(
            data: mq.copyWith(size: Size(w, h), devicePixelRatio: mq.devicePixelRatio * scale),
            child: child,
          ),
        ),
      );
    });
  }
}
