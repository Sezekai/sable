import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/db.dart';
import '../core/jobs.dart';
import '../core/library.dart';
import '../core/settings.dart';
import 'app.dart';
import 'filters_panel.dart';
import 'reader_page.dart';
import 'widgets.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => LibraryPageState();
}

/// A library folder's name as shown in filters.
String _folderName(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((x) => x.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

/// The library's scrolling: twice as far for each notch of the mouse wheel.
class _FastScroll extends ScrollController {
  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _FastPosition(physics: physics, context: context, oldPosition: oldPosition, debugLabel: debugLabel);
}

class _FastPosition extends ScrollPositionWithSingleContext {
  _FastPosition({required super.physics, required super.context, super.oldPosition, super.debugLabel});
  @override
  void pointerScroll(double delta) {
    // Ctrl+wheel changes the cover size instead.
    if (HardwareKeyboard.instance.isControlPressed) return;
    super.pointerScroll(delta * 2);
  }
}

class LibraryPageState extends State<LibraryPage> {
  final search = TextEditingController(text: Library.I.filter.search);
  final Set<String> ticked = {}; // volume keys
  String? _lastTick;
  final scroll = _FastScroll();
  List<Entry> _entries = [];

  static void noop() {}

  @override
  void dispose() {
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  List<Volume> get tickedVolumes => [
    for (final k in ticked)
      if (Library.I.volumes[k] != null) Library.I.volumes[k]!,
  ];

  void _tickEntry(Entry e, {bool range = false}) {
    final keys = e.volumes.map((v) => v.key).toList();
    setState(() {
      if (range && _lastTick != null) {
        final a = _entries.indexWhere((x) => x.volumes.any((v) => v.key == _lastTick));
        final b = _entries.indexOf(e);
        if (a >= 0 && b >= 0) {
          for (var i = min(a, b); i <= max(a, b); i++) {
            ticked.addAll(_entries[i].volumes.map((v) => v.key));
          }
          return;
        }
      }
      if (keys.every(ticked.contains)) {
        ticked.removeAll(keys);
      } else {
        ticked.addAll(keys);
      }
      _lastTick = keys.first;
    });
  }

  void _open(Entry e) {
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (ctrl || shift || ticked.isNotEmpty) {
      _tickEntry(e, range: shift);
      return;
    }
    Nav.I.openEntry(e);
  }

  void _read(Entry e) {
    final v = e is SeriesEntry ? e.next : e.cover;
    openBook(context, v.primary);
  }

  void _random() {
    if (_entries.isEmpty) return;
    final e = _entries[Random().nextInt(_entries.length)];
    Nav.I.openEntry(e);
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent || typingInField) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyA) {
      setState(() => ticked.addAll(_entries.expand((x) => x.volumes).map((v) => v.key)));
      return KeyEventResult.handled;
    }
    if (ctrl) return KeyEventResult.ignored;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.keyR:
        _random();
      case LogicalKeyboardKey.equal || LogicalKeyboardKey.add || LogicalKeyboardKey.numpadAdd:
        _zoom(16);
      case LogicalKeyboardKey.minus || LogicalKeyboardKey.numpadSubtract:
        _zoom(-16);
      case LogicalKeyboardKey.escape:
        if (ticked.isEmpty) return KeyEventResult.ignored;
        setState(ticked.clear);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _zoom(double d) {
    Settings.I.tileSize = (Settings.I.tileSize + d).clamp(110, 300);
    Settings.I.save();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: ListenableBuilder(
        listenable: Listenable.merge([Library.I, Settings.I, Covers.I]),
        builder: (context, _) {
          _entries = Library.I.entries();
          ticked.removeWhere((k) => !Library.I.volumes.containsKey(k));
          return Column(
            children: [
              _toolbar(),
              if (Library.I.unavailableRoots.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Banner1(
                    icon: Icons.usb_off_outlined,
                    lead: 'Some folders can\'t be reached.',
                    text: '${Library.I.unavailableRoots.join(', ')}. Is the drive connected? Books there are kept as they were.',
                    action: Btn.ghost('Retry', onTap: Library.I.scan),
                  ),
                ),
              _activeFilters(),
              Expanded(child: _body()),
              if (ticked.isNotEmpty) _selectionBar(),
            ],
          );
        },
      ),
    );
  }

  Widget _toolbar() {
    final s = Settings.I;
    final f = Library.I.filter;
    final nFilters =
        [
          f.read,
          f.inProgress,
          f.favourite,
          f.rated,
          f.series,
          f.ln,
          f.pdf,
          f.ratingRange,
          f.readCount,
          f.lengthRange,
          f.readIn,
        ].where((t) => t != Tri.any).length +
        f.authors.length +
        f.excludeAuthors.length +
        f.tags.length +
        f.excludeTags.length +
        f.folders.length +
        f.excludeFolders.length;
    final hasCollections = Library.I.books.any((b) => b.collection && !b.missing);
    final gap = SizedBox(width: 8);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: LayoutBuilder(
        builder: (context, box) {
          // Narrow windows: smaller boxes, and the cover-size slider moves to + − / Ctrl+wheel.
          final narrow = box.maxWidth < 1350;
          return SizedBox(
            height: lk.hControl + 4,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text('Library', style: ts(size: 18, w: FontWeight.w700)),
                const SizedBox(width: 8),
                Text('${_entries.length}', style: ts(c: tk.faint, tab: true)),
                const SizedBox(width: 12),
                // All, books only or light novels only.
                Seg<Tri>(
                  value: f.ln,
                  items: const [(Tri.any, 'All'), (Tri.no, 'Books'), (Tri.yes, 'LNs')],
                  onChanged: (v) {
                    f.ln = v;
                    Library.I.changed();
                  },
                ),
                const SizedBox(width: 12),
                // The search box takes all the room that's left.
                Expanded(
                  child: Field(
                    controller: search,
                    focusNode: Nav.I.searchFocus,
                    hint: 'Search titles, series, authors and tags  ( / )',
                    icon: Icons.search,
                    onChanged: (v) {
                      Library.I.filter.search = v;
                      Library.I.changed();
                    },
                  ),
                ),
                gap,
                if (Settings.I.folders.length > 1) ...[
                  Drop<String>(
                    value: f.folders.length == 1 && f.excludeFolders.isEmpty ? f.folders.first : '',
                    width: narrow ? 130 : 170,
                    items: [
                      ('', f.folders.length > 1 || f.excludeFolders.isNotEmpty ? 'Some folders' : 'All folders'),
                      for (final lf in Settings.I.folders) (lf.path, _folderName(lf.path)),
                    ],
                    onChanged: (v) {
                      f.folders = v.isEmpty ? {} : {v};
                      f.excludeFolders = {};
                      Library.I.changed();
                    },
                  ),
                  gap,
                ],
                Btn(
                  nFilters == 0 ? 'Filters' : 'Filters · $nFilters',
                  icon: Icons.filter_list,
                  onTap: () => showDialog(context: context, barrierColor: Colors.black38, builder: (_) => const FiltersPanel()),
                ),
                if (nFilters > 0) ...[
                  const SizedBox(width: 2),
                  IconBtn(
                    Icons.filter_list_off,
                    tooltip: 'Clear all filters',
                    onTap: () {
                      Library.I.filter = LibFilter()..search = f.search;
                      Library.I.changed();
                    },
                  ),
                ],
                gap,
                Drop<String>(
                  value: s.sort,
                  width: narrow ? 140 : 170,
                  items: [for (final e in sortKeys.entries) (e.key, e.value)],
                  onChanged: (v) {
                    s.sort = v;
                    if (v == 'random') Library.I.reshuffle();
                    s.save();
                  },
                ),
                const SizedBox(width: 2),
                IconBtn(
                  s.sortDesc ? Icons.arrow_downward : Icons.arrow_upward,
                  tooltip: s.sortDesc ? 'Newest / highest first. Click to reverse.' : 'Oldest / lowest first. Click to reverse.',
                  onTap: () {
                    s.sortDesc = !s.sortDesc;
                    s.save();
                  },
                ),
                if (hasCollections) ...[
                  gap,
                  if (narrow)
                    IconBtn(
                      Icons.collections_bookmark_outlined,
                      active: s.showCollections,
                      tooltip: s.showCollections
                          ? 'Collections shown. Click to hide them.'
                          : 'Collections hidden. Click to show them.',
                      onTap: () {
                        s.showCollections = !s.showCollections;
                        s.save();
                        Library.I.changed();
                      },
                    )
                  else
                    Btn(
                      s.showCollections ? 'Collections shown' : 'Collections hidden',
                      icon: s.showCollections ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      tooltip: 'Show or hide the books from your downloaded collections',
                      onTap: () {
                        s.showCollections = !s.showCollections;
                        s.save();
                        Library.I.changed();
                      },
                    ),
                ],
                gap,
                Container(width: 1, height: lk.hControl - 6, color: tk.line),
                gap,
                IconBtn(Icons.casino_outlined, tooltip: 'Random book from what\'s shown (R)', onTap: _random),
                PopupMenuButton<String>(
                  tooltip: 'View',
                  padding: EdgeInsets.zero,
                  onSelected: (v) {
                    if (v == 'list') {
                      s.listView = !s.listView;
                    } else if (v == 'continue') {
                      s.showContinue = !s.showContinue;
                    } else {
                      s.gridStyle = v;
                      s.listView = false;
                    }
                    s.save();
                  },
                  itemBuilder: (_) => [
                    for (final (k, l) in [
                      ('comfortable', 'Comfortable grid'),
                      ('compact', 'Compact grid'),
                      ('cover', 'Covers only'),
                    ])
                      PopupMenuItem(
                        value: k,
                        child: Text(l, style: ts(c: !s.listView && s.gridStyle == k ? lk.acc : tk.text)),
                      ),
                    PopupMenuItem(
                      value: 'list',
                      child: Text('List', style: ts(c: s.listView ? lk.acc : tk.text)),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'continue',
                      child: Text('${s.showContinue ? 'Hide' : 'Show'} "Continue reading"', style: ts()),
                    ),
                  ],
                  child: const IgnorePointer(child: IconBtn(Icons.grid_view_outlined, onTap: noop)),
                ),
                if (!narrow)
                  Tooltip(
                    message: 'Cover size (+ −, Ctrl+wheel)',
                    child: SizedBox(
                      width: 120,
                      child: Slider(
                        value: s.tileSize,
                        min: 110,
                        max: 300,
                        onChanged: (v) => setState(() => s.tileSize = v),
                        onChangeEnd: (_) => s.save(),
                      ),
                    ),
                  ),
                IconBtn(
                  Icons.refresh,
                  tooltip: Jobs.I.isQueued(Library.scanName) ? 'Scanning…' : 'Scan the library for new books',
                  onTap: Library.I.scan,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _activeFilters() {
    final f = Library.I.filter;
    final pills = <Widget>[];
    void tri(String on, String off, Tri v, void Function() clear) {
      if (v == Tri.any) return;
      pills.add(
        Pill(
          v == Tri.yes ? on : off,
          active: true,
          color: v == Tri.no ? tk.danger : null,
          onClose: () {
            clear();
            Library.I.changed();
          },
        ),
      );
    }

    tri('Read', 'Unread', f.read, () => f.read = Tri.any);
    tri('In progress', 'Not in progress', f.inProgress, () => f.inProgress = Tri.any);
    tri('Favourite', 'Not favourite', f.favourite, () => f.favourite = Tri.any);
    tri('Rated', 'Not rated', f.rated, () => f.rated = Tri.any);
    tri('In a series', 'Single book', f.series, () => f.series = Tri.any);
    tri('Light novels', 'Books', f.ln, () => f.ln = Tri.any);
    tri('PDF only', 'Not PDF', f.pdf, () => f.pdf = Tri.any);
    tri(
      'Rating ${f.minRating}–${f.maxRating}',
      'Rating outside ${f.minRating}–${f.maxRating}',
      f.ratingRange,
      () => f.ratingRange = Tri.any,
    );
    tri('Read ${f.readCountMin}+ times', 'Read fewer times', f.readCount, () => f.readCount = Tri.any);
    tri(
      '${f.minLength}–${f.maxLength} pages',
      'Not ${f.minLength}–${f.maxLength} pages',
      f.lengthRange,
      () => f.lengthRange = Tri.any,
    );
    tri('Read in ${f.readInDays} days', 'Not read in ${f.readInDays} days', f.readIn, () => f.readIn = Tri.any);
    for (final d in [...f.folders, ...f.excludeFolders]) {
      final neg = f.excludeFolders.contains(d);
      pills.add(
        Pill(
          neg ? 'not in ${_folderName(d)}' : 'In ${_folderName(d)}',
          active: true,
          color: neg ? tk.danger : null,
          onClose: () {
            f.folders.remove(d);
            f.excludeFolders.remove(d);
            Library.I.changed();
          },
        ),
      );
    }
    for (final a in [...f.authors, ...f.excludeAuthors]) {
      final neg = f.excludeAuthors.contains(a);
      pills.add(
        Pill(
          neg ? 'not $a' : a,
          active: true,
          color: neg ? tk.danger : null,
          onClose: () {
            f.authors.remove(a);
            f.excludeAuthors.remove(a);
            Library.I.changed();
          },
        ),
      );
    }
    for (final id in [...f.tags, ...f.excludeTags]) {
      final t = Library.I.tagById(id);
      if (t == null) continue;
      final neg = f.excludeTags.contains(id);
      pills.add(
        Pill(
          neg ? 'not ${t.name}' : t.name,
          active: true,
          color: neg ? tk.danger : Color(t.color),
          onClose: () {
            f.tags.remove(id);
            f.excludeTags.remove(id);
            Library.I.changed();
          },
        ),
      );
    }
    if (pills.isEmpty) return const SizedBox();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(child: Wrap(spacing: 6, runSpacing: 6, children: pills)),
          Btn.ghost(
            'Clear all',
            dense: true,
            onTap: () {
              Library.I.filter = LibFilter()..search = f.search;
              Library.I.changed();
            },
          ),
        ],
      ),
    );
  }

  Widget _selectionBar() {
    final vs = tickedVolumes;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: tk.panel,
        border: Border(top: BorderSide(color: tk.line)),
      ),
      child: Row(
        children: [
          Text('${vs.length} ticked', style: ts(w: FontWeight.w600)),
          const SizedBox(width: 12),
          Btn(
            'Mark read',
            icon: Icons.done_all,
            dense: true,
            onTap: () {
              Library.I.markRead(vs, true);
              toast('Marked ${vs.length} read');
            },
          ),
          const SizedBox(width: 6),
          Btn(
            'Mark unread',
            icon: Icons.remove_done,
            dense: true,
            onTap: () {
              Library.I.markRead(vs, false);
              toast('Marked ${vs.length} unread');
            },
          ),
          const SizedBox(width: 6),
          Btn('Favourite', icon: Icons.favorite_border, dense: true, onTap: () => Library.I.toggleFavourite(vs)),
          const SizedBox(width: 6),
          TagMenu(volumes: vs),
          const Spacer(),
          Btn.ghost(
            'Tick all shown',
            dense: true,
            onTap: () => setState(() => ticked.addAll(_entries.expand((x) => x.volumes).map((v) => v.key))),
          ),
          Btn.ghost('Clear', dense: true, onTap: () => setState(ticked.clear)),
        ],
      ),
    );
  }

  Widget _body() {
    if (Library.I.books.isEmpty) {
      final scanning = Jobs.I.isQueued(Library.scanName);
      return EmptyState(
        icon: Icons.auto_stories_outlined,
        text: scanning
            ? 'Looking for books… they appear here as they\'re found.'
            : 'No books yet.\nSable reads EPUB, PDF, MOBI and AZW3 files (also inside ZIPs) from the folders in Settings.',
        action: scanning ? null : Btn.primary('Scan the library', icon: Icons.refresh, onTap: Library.I.scan),
      );
    }
    if (_entries.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        text: 'Nothing matches these filters.',
        action: Btn(
          'Clear filters',
          onTap: () {
            search.clear();
            Library.I.filter = LibFilter();
            Library.I.changed();
          },
        ),
      );
    }
    final s = Settings.I;
    final f = Library.I.filter;
    final cont = s.showContinue && f.isEmpty ? Library.I.continueReading() : <Volume>[];
    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent && HardwareKeyboard.instance.isControlPressed) {
          _zoom(e.scrollDelta.dy < 0 ? 12 : -12);
          GestureBinding.instance.pointerSignalResolver.register(e, (_) {});
        }
      },
      child: Scrollbar(
        controller: scroll,
        child: CustomScrollView(
          controller: scroll,
          slivers: [
            if (cont.isNotEmpty) SliverToBoxAdapter(child: _continueStrip(cont)),
            if (cont.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    'All books',
                    style: ts(w: FontWeight.w700, c: tk.sec),
                  ),
                ),
              ),
            if (s.listView) _list() else _grid(),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  Widget _continueStrip(List<Volume> vs) {
    const w = 104.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 0, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Continue reading',
            style: ts(w: FontWeight.w700, c: tk.sec),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: w * 1.5 + 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: vs.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final v = vs[i];
                final b = v.primary;
                return Hoverable(
                  builder: (h) => GestureDetector(
                    onTap: () => openBook(context, b),
                    onSecondaryTap: () => Nav.I.openVolume(v),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: SizedBox(
                        width: w,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AnimatedScale(
                              scale: h ? 1.03 : 1,
                              duration: const Duration(milliseconds: 120),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(lk.rControl),
                                child: SizedBox(
                                  width: w,
                                  height: w * 1.5,
                                  child: Stack(
                                    children: [
                                      Positioned.fill(
                                        child: BookCover(book: b, width: w),
                                      ),
                                      Positioned(left: 0, right: 0, bottom: 0, child: ProgressLine(value: v.progress)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              b.cardTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ts(size: 12, w: FontWeight.w600),
                            ),
                            Text(
                              '${(v.progress * 100).floor()}%${b.volumeText.isEmpty ? '' : ' · ${b.volumeText}'}',
                              maxLines: 1,
                              style: ts(size: 11, c: tk.faint, tab: true),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _grid() {
    final s = Settings.I;
    final textH = s.gridStyle == 'comfortable' ? 40.0 : 0.0;
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(13, 0, 13, 0),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: s.tileSize,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          mainAxisExtent: (s.tileSize - 6) * 1.5 + textH + 8,
        ),
        delegate: SliverChildBuilderDelegate((_, i) {
          final e = _entries[i];
          return EntryCard(
            entry: e,
            style: s.gridStyle,
            ticked: e.volumes.every((v) => ticked.contains(v.key)),
            anyTicked: ticked.isNotEmpty,
            onTap: () => _open(e),
            onDouble: () => _read(e),
            onTick: () => _tickEntry(e),
          );
        }, childCount: _entries.length),
      ),
    );
  }

  Widget _list() {
    return SliverList.builder(
      itemCount: _entries.length,
      itemBuilder: (_, i) {
        final e = _entries[i];
        final v = e.cover;
        final b = v.any;
        final isTicked = e.volumes.every((x) => ticked.contains(x.key));
        final series = e is SeriesEntry;
        return Hoverable(
          builder: (h) => GestureDetector(
            onTap: () => _open(e),
            onDoubleTap: () => _read(e),
            child: Container(
              height: 52,
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: isTicked ? lk.tint(tk.ground, 0.17) : (h ? tk.raised : null),
                borderRadius: BorderRadius.circular(lk.rControl),
              ),
              child: Row(
                children: [
                  if (ticked.isNotEmpty) Checkbox(value: isTicked, onChanged: (_) => _tickEntry(e)),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: SizedBox(width: 30, height: 44, child: BookCover(book: b, width: 30)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 5,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.name,
                          style: ts(w: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          series ? '${e.volumes.length} volumes' : (b.cardSub.isEmpty ? b.kind.label : b.cardSub),
                          style: ts(size: 12, c: tk.faint),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      b.displayAuthor ?? '',
                      style: ts(c: tk.sec),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    child: Text(
                      series ? '${e.readCount}/${e.volumes.length} read' : '${(v.progress * 100).floor()}%',
                      style: ts(c: tk.sec, tab: true),
                    ),
                  ),
                  SizedBox(width: 80, child: v.rating > 0 ? Stars(value: v.rating, size: 13) : const SizedBox()),
                  SizedBox(
                    width: 90,
                    child: Text(v.lastReadAt > 0 ? dateText(v.lastReadAt) : '', style: ts(c: tk.faint, size: 12)),
                  ),
                  SizedBox(
                    width: 56,
                    child: Text(v.files.map((x) => x.format.toUpperCase()).toSet().join(' '), style: ts(c: tk.faint, size: 11)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A book's cover, or a made-up one from its title when there's no picture.
class BookCover extends StatelessWidget {
  const BookCover({super.key, required this.book, required this.width, this.fit = BoxFit.cover});
  final Book book;
  final double width;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final f = Covers.I.cached(book);
    if (f == null) return _made();
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Image.file(
      f,
      key: ValueKey('${f.path}${Covers.I.version}'),
      fit: fit,
      cacheWidth: (width * dpr).round().clamp(32, 720),
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => _made(),
    );
  }

  Widget _made() {
    final h = book.cardTitle.hashCode;
    final a = HSVColor.fromAHSV(1, (h % 360).toDouble(), 0.45, 0.32).toColor();
    final b = HSVColor.fromAHSV(1, ((h ~/ 7) % 360).toDouble(), 0.5, 0.16).toColor();
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [a, b]),
      ),
      padding: EdgeInsets.all(width < 60 ? 2 : 10),
      child: width < 60
          ? const SizedBox()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book.cardTitle,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: width / 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    height: 1.15,
                  ),
                ),
                const Spacer(),
                if (book.volumeText.isNotEmpty)
                  Text(
                    book.volumeText,
                    style: TextStyle(fontFamily: 'Inter', fontSize: width / 13, color: Colors.white70),
                  ),
                if (book.displayAuthor != null)
                  Text(
                    book.displayAuthor!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: 'Inter', fontSize: width / 14, color: Colors.white70),
                  ),
              ],
            ),
    );
  }
}

class ProgressLine extends StatelessWidget {
  const ProgressLine({super.key, required this.value});
  final double value;
  @override
  Widget build(BuildContext context) {
    if (value <= 0) return const SizedBox();
    return Container(
      height: 3,
      color: Colors.black54,
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: value.clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(gradient: value >= 1 ? null : lk.grad, color: value >= 1 ? tk.ok : null),
        ),
      ),
    );
  }
}

Widget badge(IconData? icon, String? text, {Color? color}) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(5)),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (icon != null) Icon(icon, size: 12, color: color ?? Colors.white),
      if (icon != null && text != null) const SizedBox(width: 3),
      if (text != null)
        Text(
          text,
          style: ts(size: 11, c: Colors.white, w: FontWeight.w600, tab: true),
        ),
    ],
  ),
);

class EntryCard extends StatelessWidget {
  const EntryCard({
    super.key,
    required this.entry,
    required this.style,
    required this.ticked,
    required this.anyTicked,
    required this.onTap,
    required this.onDouble,
    required this.onTick,
  });
  final Entry entry;
  final String style;
  final bool ticked;
  final bool anyTicked;
  final VoidCallback onTap;
  final VoidCallback onDouble;
  final VoidCallback onTick;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final v = e.cover;
    final b = v.any;
    final series = e is SeriesEntry ? e : null;
    final progress = Library.I.entryProgress(e);
    final fav = e.volumes.any((x) => x.favourite);
    final r = series == null ? v.rating : 0.0;
    final reads = series == null ? v.readCount : 0;
    final pdfOnly = series == null && v.files.every((x) => x.format == 'pdf');
    final title = series?.label ?? b.cardTitle;
    final sub = series != null
        ? '${series.volumes.length} volumes${series.editions.length > 1 ? ' · ${series.editions.length} editions' : ''}'
        : (b.cardSub.isNotEmpty ? b.cardSub : (b.displayAuthor ?? ''));
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth - 6;
        final cover = Stack(
          children: [
            Positioned.fill(
              child: BookCover(book: b, width: w),
            ),
            if (series != null)
              Positioned(left: 6, top: 6, child: badge(Icons.layers_outlined, '${series.readCount}/${series.volumes.length}')),
            if (fav) Positioned(right: 6, top: 6, child: badge(Icons.favorite, null, color: const Color(0xFFFF6FB1))),
            if (pdfOnly && style != 'cover') Positioned(left: 6, top: 6, child: badge(null, 'PDF')),
            if (r > 0 && style != 'cover')
              Positioned(left: 6, bottom: 8, child: badge(Icons.star_rounded, r.toString().replaceAll('.0', ''))),
            if (reads > 1) Positioned(right: 6, bottom: 8, child: badge(null, '×$reads')),
            if (style == 'compact')
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(6, 22, 6, 8),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0xE6000000)],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: ts(c: Colors.white, size: 12, w: FontWeight.w600),
                      ),
                      if (sub.isNotEmpty)
                        Text(
                          sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts(c: Colors.white70, size: 11),
                        ),
                    ],
                  ),
                ),
              ),
            if (Settings.I.progressLine) Positioned(left: 0, right: 0, bottom: 0, child: ProgressLine(value: progress)),
            if (anyTicked || ticked)
              Positioned(
                right: 4,
                bottom: 6,
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(value: ticked, onChanged: (_) => onTick()),
                ),
              ),
          ],
        );
        return Hoverable(
          builder: (h) => GestureDetector(
            onTap: onTap,
            onDoubleTap: onDouble,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(lk.rControl + 2),
                  color: ticked ? lk.tint(tk.ground, 0.17) : (h ? tk.raised : null),
                  border: ticked ? Border.all(color: lk.outline, width: lk.outlineWidth) : null,
                ),
                padding: const EdgeInsets.all(3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(lk.rControl - 1),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 8, offset: const Offset(0, 3)),
                          ],
                        ),
                        child: ClipRRect(borderRadius: BorderRadius.circular(lk.rControl - 1), child: cover),
                      ),
                    ),
                    if (style == 'comfortable') ...[
                      const SizedBox(height: 5),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts(size: 12.5, w: FontWeight.w600),
                      ),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts(size: 11.5, c: tk.faint),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// "Tags" menu for ticked or opened books.
class TagMenu extends StatelessWidget {
  const TagMenu({super.key, required this.volumes, this.compact = false});
  final List<Volume> volumes;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final tags = Library.I.tags;
    bool has(Tag t) => volumes.every((v) => Library.I.tagsOfVolume(v).contains(t.id));
    return PopupMenuButton<int>(
      tooltip: '',
      onSelected: (id) async {
        if (id == -1) {
          final name = await ask(
            context,
            'New tag',
            body: 'Tags group books, like "To read" or "On hold".',
            confirmLabel: 'Create tag',
          );
          if (name == null || name.isEmpty) return;
          final tag = Library.I.createTag(name);
          Library.I.addTag(tag, volumes);
          toast('Added ${volumes.length} to $name');
          return;
        }
        final tag = Library.I.tagById(id)!;
        if (has(tag)) {
          Library.I.removeTag(tag, volumes);
          toast('Removed ${volumes.length} from ${tag.name}');
        } else {
          Library.I.addTag(tag, volumes);
          toast('Added ${volumes.length} to ${tag.name}');
        }
      },
      itemBuilder: (_) => [
        for (final t in tags)
          PopupMenuItem(
            value: t.id,
            child: Row(
              children: [
                Icon(has(t) ? Icons.check_box : Icons.check_box_outline_blank, size: 16, color: Color(t.color)),
                const SizedBox(width: 8),
                Text(t.name, style: ts()),
              ],
            ),
          ),
        PopupMenuItem(
          value: -1,
          child: Text('New tag…', style: ts(c: lk.acc)),
        ),
      ],
      child: const IgnorePointer(
        child: Btn('Tags', icon: Icons.sell_outlined, dense: true, onTap: LibraryPageState.noop),
      ),
    );
  }
}

bool fileExists(String path) => File(path).existsSync();
