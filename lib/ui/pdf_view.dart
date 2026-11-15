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
      final im = await pg.render(fullWidth: w.toDouble(), fullHeight: h.toDouble(), width: w, height: h, backgroundColor: 0xffffffff);
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

  Future<void> _render(int i, int w, int h) async {
    final key = '$i@${w}x$h';
    if (_images.containsKey(key) || _rendering.contains(key) || _doc == null) return;
    _rendering.add(key);
    try {
      final im = await _doc!.pages[i].render(
          fullWidth: w.toDouble(), fullHeight: h.toDouble(), width: w, height: h, backgroundColor: 0xffffffff);
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
        final far = (page - _current).abs() > 4 || !k.endsWith('@${w}x$h') && page == i;
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
      return Center(child: Text('Opening the PDF…', style: TextStyle(color: widget.background.computeLuminance() > 0.5 ? Colors.black54 : Colors.white54)));
    }
    return LayoutBuilder(builder: (context, c) {
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
      for (final i in spread) {
        final pg = _doc!.pages[i];
        final aspect = pg.width / pg.height;
        var h = availH, w = h * aspect;
        if (w > availW) {
          w = availW;
          h = w / aspect;
        }
        final pw = (w * dpr).round(), ph = (h * dpr).round();
        final img = _images['$i@${pw}x$ph'];
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
              child: page);
        }
        pages.add(page);
      }
      final nextStart = _current + spread.length;
      if (nextStart < _count) {
        for (final i in _spreadAt(nextStart)) {
          final pg = _doc!.pages[i];
          final aspect = pg.width / pg.height;
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
    });
  }
}
