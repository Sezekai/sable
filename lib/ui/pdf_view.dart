import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../core/books.dart';
import '../core/settings.dart';

/// PDF page count and a cover, for the library scan.
Future<(int, Uint8List?)> inspectPdfFile(String path) async {
  await pdfrxFlutterInitialize();
  final doc = await PdfDocument.openFile(path);
  try {
    final n = doc.pages.length;
    Uint8List? cover;
    if (n > 0) {
      final pg = doc.pages.first;
      const w = 360;
      final h = (w * pg.height / pg.width).round().clamp(1, 1200);
      final im = await pg.render(
        fullWidth: w.toDouble(),
        fullHeight: h.toDouble(),
        width: w,
        height: h,
        backgroundColor: 0xffffffff,
      );
      if (im != null) {
        final px = im.pixels, iw = im.width, ih = im.height;
        cover = await Isolate.run(() => coverFromBgra(px, iw, ih));
        im.dispose();
      }
    }
    return (n, cover);
  } finally {
    await doc.dispose();
  }
}

class PdfOutlineItem {
  PdfOutlineItem(this.label, this.page, this.level);
  final String label;
  final int page; // 0-based
  final int level;
}

/// Controls a [PdfPager] from the reader.
class PdfPagerController {
  _PdfPagerState? _s;
  void next() => _s?._step(1);
  void prev() => _s?._step(-1);
  void goToPage(int i) => _s?._goPage(i);
  void goToFraction(double f) {
    final n = _s?._count ?? 0;
    if (n > 0) _s?._goPage((f * (n - 1)).round());
  }

  void first() => _s?._goPage(0);
  void last() => _s?._goPage((_s?._count ?? 1) - 1);
  int get pageCount => _s?._count ?? 0;
}

/// A PDF shown one or two pages at a time, fitted to the window.
class PdfPager extends StatefulWidget {
  const PdfPager({
    super.key,
    required this.path,
    required this.controller,
    required this.startPage,
    required this.layout,
    required this.background,
    required this.darkPages,
    this.crop = false,
    required this.onReady,
    required this.onPage,
    required this.onTapZone,
    required this.onError,
  });
  final String path;
  final PdfPagerController controller;
  final int startPage;
  final PageLayout layout;
  final Color background;
  final bool darkPages;

  /// Trim plain white or black borders from each page.
  final bool crop;
  final void Function(int pageCount, List<PdfOutlineItem> outline) onReady;

  /// First and last page shown (0-based) and the page count.
  final void Function(int first, int last, int count) onPage;
  final void Function(double x) onTapZone;
  final void Function(String message) onError;

  @override
  State<PdfPager> createState() => _PdfPagerState();
}

class _PdfPagerState extends State<PdfPager> {
  PdfDocument? _doc;
  int _count = 0;
  int _current = 0; // first page of the current spread
  bool _two = false;
  final Map<String, ui.Image> _images = {};
  final Set<String> _rendering = {};
  Size _lastSize = Size.zero;

  /// The part of each page kept when cropping, as fractions of the page.
  final Map<int, Rect> _crops = {};
  final Set<int> _cropping = {};

  @override
  void initState() {
    super.initState();
    widget.controller._s = this;
    _open();
  }

  Future<void> _open() async {
    try {
      await pdfrxFlutterInitialize();
      final d = await PdfDocument.openFile(widget.path);
      if (!mounted) {
        await d.dispose();
        return;
      }
      _doc = d;
      _count = d.pages.length;
      _current = widget.startPage.clamp(0, _count == 0 ? 0 : _count - 1);
      final outline = <PdfOutlineItem>[];
      try {
        void walk(List<PdfOutlineNode> ns, int level) {
          for (final n in ns) {
            final pn = n.dest?.pageNumber;
            if (pn != null) outline.add(PdfOutlineItem(n.title, pn - 1, level));
            walk(n.children, level + 1);
          }
        }

        walk(await d.loadOutline(), 0);
      } catch (_) {}
      setState(() {});
      widget.onReady(_count, outline);
      WidgetsBinding.instance.addPostFrameCallback((_) => _report());
    } catch (e) {
      widget.onError('$e');
    }
  }

  @override
  void dispose() {
    widget.controller._s = null;
    for (final im in _images.values) {
      im.dispose();
    }
    _doc?.dispose();
    super.dispose();
  }

  /// Finds the plain border around page [i] from a small render of it.
  Future<void> _findCrop(int i) async {
    if (_crops.containsKey(i) || _cropping.contains(i) || _doc == null) return;
    _cropping.add(i);
    try {
      final pg = _doc!.pages[i];
      const w = 160;
      final h = (w * pg.height / pg.width).round().clamp(8, 1000);
      final im = await pg.render(
        fullWidth: w.toDouble(),
        fullHeight: h.toDouble(),
        width: w,
        height: h,
        backgroundColor: 0xffffffff,
      );
      if (im == null) {
        _crops[i] = const Rect.fromLTRB(0, 0, 1, 1);
      } else {
        _crops[i] = findPageCrop(im.pixels, im.width, im.height);
        im.dispose();
      }
    } catch (_) {
      _crops[i] = const Rect.fromLTRB(0, 0, 1, 1);
    } finally {
      _cropping.remove(i);
    }
    if (mounted) setState(() {});
  }

  /// The page's shape on screen (width / height), after any cropping.
  double _aspect(int i) {
    final pg = _doc!.pages[i];
    final c = widget.crop ? _crops[i] : null;
    if (c == null) return pg.width / pg.height;
    return (pg.width * c.width) / (pg.height * c.height);
  }

  bool _landscape(int i) {
    final p = _doc!.pages[i];
    return p.width > p.height;
  }

  /// Pages shown together starting at [i]: the first page alone (the cover),
  /// wide pages alone, the rest in pairs.
  List<int> _spreadAt(int i) {
    if (!_two || i == 0 || _landscape(i) || i + 1 >= _count || _landscape(i + 1)) return [i];
    return [i, i + 1];
  }

  /// The start of the spread that contains page [i].
  int _spreadStart(int i) {
    if (!_two) return i;
    var s = 0;
    while (s < _count) {
      final sp = _spreadAt(s);
      if (sp.contains(i)) return s;
      s += sp.length;
    }
    return i;
  }

  void _step(int dir) {
    if (_doc == null) return;
    if (dir > 0) {
      final sp = _spreadAt(_current);
      final n = _current + sp.length;
      if (n < _count) _goPage(n);
    } else if (_current > 0) {
      _goPage(_spreadStart(_current - 1));
    }
  }

  void _goPage(int i) {
    if (_doc == null || _count == 0) return;
    setState(() => _current = _spreadStart(i.clamp(0, _count - 1)));
    _report();
  }

  void _report() {
    if (_doc == null || _count == 0) return;
    final sp = _spreadAt(_current);
    widget.onPage(sp.first, sp.last, _count);
  }

  String _key(int i, int w, int h) {
    final c = widget.crop ? _crops[i] : null;
    return c == null ? '$i@${w}x$h' : '$i@${w}x${h}c';
  }

  Future<void> _render(int i, int w, int h) async {
    final key = _key(i, w, h);
    if (_images.containsKey(key) || _rendering.contains(key) || _doc == null) return;
    final c = widget.crop ? _crops[i] : null;
    _rendering.add(key);
    try {
      // A cropped page: draw the whole page bigger and keep only the middle part.
      final fw = c == null ? w.toDouble() : w / c.width;
      final fh = c == null ? h.toDouble() : h / c.height;
      final im = await _doc!.pages[i].render(
        x: c == null ? 0 : (c.left * fw).round(),
        y: c == null ? 0 : (c.top * fh).round(),
        fullWidth: fw,
        fullHeight: fh,
        width: w,
        height: h,
        backgroundColor: 0xffffffff,
      );
      if (im == null) return;
      final ui.Image image = await im.createImage();
      im.dispose();
      if (!mounted) {
        image.dispose();
        return;
      }
      // Keep only images near the current page.
      _images.removeWhere((k, v) {
        final page = int.parse(k.split('@').first);
        final far = (page - _current).abs() > 4 || k != key && page == i;
        if (far) v.dispose();
        return far;
      });
      setState(() => _images[key] = image);
    } catch (_) {
    } finally {
      _rendering.remove(key);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_doc == null) {
      return Center(
        child: Text(
          'Opening the PDF…',
          style: TextStyle(color: widget.background.computeLuminance() > 0.5 ? Colors.black54 : Colors.white54),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final wantTwo = switch (widget.layout) {
          PageLayout.one => false,
          PageLayout.two => true,
          PageLayout.auto => size.width > size.height * 1.15,
        };
        if (wantTwo != _two || size != _lastSize) {
          _two = wantTwo;
          _lastSize = size;
          final start = _spreadStart(_current);
          if (start != _current) {
            _current = start;
            WidgetsBinding.instance.addPostFrameCallback((_) => _report());
          }
        }
        final spread = _spreadAt(_current);
        const pad = 12.0;
        // Room at the bottom for the reader's status line.
        final availH = size.height - pad - 34;
        final availW = (size.width - pad * 2) / spread.length;
        final pages = <Widget>[];
        if (widget.crop) {
          final waiting = [
            for (final i in spread)
              if (!_crops.containsKey(i)) i,
          ];
          if (waiting.isNotEmpty) {
            for (final i in waiting) {
              unawaited(_findCrop(i));
            }
            return Container(color: widget.background);
          }
        }
        for (final i in spread) {
          final aspect = _aspect(i);
          var h = availH, w = h * aspect;
          if (w > availW) {
            w = availW;
            h = w / aspect;
          }
          final pw = (w * dpr).round(), ph = (h * dpr).round();
          final img = _images[_key(i, pw, ph)];
          if (img == null) unawaited(_render(i, pw, ph));
          // Pre-render the next spread.
          Widget page = SizedBox(
            width: w,
            height: h,
            child: img == null
                ? Container(color: const Color(0xFF1A1A1E))
                : RawImage(image: img, width: w, height: h, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
          );
          if (widget.darkPages) {
            page = ColorFiltered(
              colorFilter: const ColorFilter.matrix(<double>[
                -0.85, 0, 0, 0, 230, //
                0, -0.85, 0, 0, 230, //
                0, 0, -0.85, 0, 230, //
                0, 0, 0, 1, 0,
              ]),
              child: page,
            );
          }
          pages.add(page);
        }
        final nextStart = _current + spread.length;
        if (nextStart < _count) {
          for (final i in _spreadAt(nextStart)) {
            if (widget.crop && !_crops.containsKey(i)) {
              unawaited(_findCrop(i));
              continue;
            }
            final aspect = _aspect(i);
            var h = availH, w = h * aspect;
            if (w > availW) {
              w = availW;
              h = w / aspect;
            }
            unawaited(_render(i, (w * dpr).round(), (h * dpr).round()));
          }
        }
        return Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) _step(e.scrollDelta.dy > 0 ? 1 : -1);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => widget.onTapZone(d.localPosition.dx / size.width),
            child: Container(
              color: widget.background,
              padding: const EdgeInsets.only(top: pad, bottom: 34),
              alignment: Alignment.center,
              child: Row(mainAxisSize: MainAxisSize.min, children: pages),
            ),
          ),
        );
      },
    );
  }
}

/// The part of a page to keep when trimming its plain border, as fractions of
/// the page. [px] is BGRA. Only white or black margins count as border; at
/// most a third is trimmed from each side.
Rect findPageCrop(Uint8List px, int w, int h) {
  int lum(int x, int y) {
    final o = (y * w + x) * 4;
    return (px[o] * 114 + px[o + 1] * 587 + px[o + 2] * 299) ~/ 1000;
  }

  if (w < 8 || h < 8) return const Rect.fromLTRB(0, 0, 1, 1);
  final bg = lum(1, 1);
  if (bg <= 225 && bg >= 30) return const Rect.fromLTRB(0, 0, 1, 1);
  bool blank(int x, int y) => (lum(x, y) - bg).abs() < 18;
  // A line counts as border when almost all of it is the border colour
  // (a speck or two of scanner noise is allowed).
  bool rowBlank(int y) {
    var ink = 0;
    for (var x = 0; x < w; x++) {
      if (!blank(x, y) && ++ink > w ~/ 100 + 1) return false;
    }
    return true;
  }

  bool colBlank(int x, int top, int bottom) {
    var ink = 0;
    for (var y = top; y <= bottom; y++) {
      if (!blank(x, y) && ++ink > h ~/ 100 + 1) return false;
    }
    return true;
  }

  var top = 0, bottom = h - 1;
  while (top < h ~/ 3 && rowBlank(top)) {
    top++;
  }
  while (bottom > h - 1 - h ~/ 3 && rowBlank(bottom)) {
    bottom--;
  }
  if (bottom <= top) return const Rect.fromLTRB(0, 0, 1, 1);
  var left = 0, right = w - 1;
  while (left < w ~/ 3 && colBlank(left, top, bottom)) {
    left++;
  }
  while (right > w - 1 - w ~/ 3 && colBlank(right, top, bottom)) {
    right--;
  }
  // Keep a little breathing room around the content.
  top = (top - 2).clamp(0, h - 1);
  left = (left - 2).clamp(0, w - 1);
  bottom = (bottom + 2).clamp(0, h - 1);
  right = (right + 2).clamp(0, w - 1);
  return Rect.fromLTRB(left / w, top / h, (right + 1) / w, (bottom + 1) / h);
}
