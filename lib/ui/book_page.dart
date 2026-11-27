import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../core/books.dart';
import '../core/db.dart';
import '../core/jobs.dart';
import '../core/library.dart';
import '../core/parse.dart';
import '../core/downloads.dart';
import '../core/extras.dart';
import '../core/platform.dart';
import '../core/settings.dart';
import 'app.dart';
import 'extras_ui.dart';
import 'library_page.dart';
import 'phone.dart';
import 'reader_page.dart';
import 'widgets.dart';

String lengthText(Book b) {
  if (b.format == 'pdf') return b.pages > 0 ? '${b.pages} pages' : '';
  if (b.textBytes <= 0) return '';
  final m = b.minutes;
  final t = m < 60 ? '$m min' : '${(m / 60).toStringAsFixed(m < 600 ? 1 : 0)} h';
  return 'about ${b.length} pages · $t to read';
}

void showInFolder(Book b) {
  final path = outerPath(b.path);
  if (Platform.isWindows) {
    Process.run('explorer.exe', ['/select,', path]);
  } else {
    Process.run('xdg-open', [p.dirname(path)]);
  }
}

/// The page's columns: the cover, the details, and (when wide) a third column,
/// with a line between each pair as long as the taller of the two.
class _Cols extends StatefulWidget {
  const _Cols({
    required this.coverW,
    required this.cover,
    required this.main,
    required this.side,
    required this.wide,
    this.flexMain = 11,
    this.flexSide = 9,
  });
  final double coverW;
  final Widget cover;
  final Widget main;
  final Widget side;
  final bool wide;
  final int flexMain;
  final int flexSide;
  @override
  State<_Cols> createState() => _ColsState();
}

class _ColsState extends State<_Cols> {
  final Map<int, double> _h = {};
  Widget _m(int i, Widget c) => _Measure(
    onHeight: (h) {
      if (mounted && (_h[i] ?? -1) != h) setState(() => _h[i] = h);
    },
    child: c,
  );
  Widget _line(double h, double gap) => Container(
    width: 1,
    height: h,
    margin: EdgeInsets.symmetric(horizontal: gap),
    color: tk.line2,
  );
  double _max(int a, int b) => math.max(_h[a] ?? 0, _h[b] ?? 0);

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(width: widget.coverW, child: _m(0, widget.cover)),
      _line(_max(0, 1), 22),
      if (widget.wide) ...[
        Expanded(flex: widget.flexMain, child: _m(1, widget.main)),
        _line(_max(1, 2), 20),
        Expanded(flex: widget.flexSide, child: _m(2, widget.side)),
      ] else
        Expanded(
          child: _m(
            1,
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [widget.main, const SizedBox(height: 20), widget.side]),
          ),
        ),
    ],
  );
}

/// Tells its parent how tall its child turned out (after each layout).
class _Measure extends SingleChildRenderObjectWidget {
  const _Measure({required this.onHeight, super.child});
  final ValueChanged<double> onHeight;
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMeasure(onHeight);
  @override
  void updateRenderObject(BuildContext context, _RenderMeasure r) => r.onHeight = onHeight;
}

class _RenderMeasure extends RenderProxyBox {
  _RenderMeasure(this.onHeight);
  ValueChanged<double> onHeight;
  double? _last;
  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (h != _last) {
      _last = h;
      WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(h));
    }
  }
}

Widget _crumbs(List<(String, VoidCallback?)> items) => Row(
  children: [
    IconBtn(
      Icons.arrow_back,
      tooltip: 'Back (Esc or the mouse\'s back button)',
      onTap: () {
        if (Nav.I.canGoBack) {
          Nav.I.back();
        } else {
          Nav.I.closeDetail();
        }
      },
    ),
    const SizedBox(width: 6),
    for (var i = 0; i < items.length; i++) ...[
      if (i > 0) Icon(Icons.chevron_right, size: 16, color: tk.faint),
      Flexible(
        child: GestureDetector(
          onTap: items[i].$2,
          child: MouseRegion(
            cursor: items[i].$2 == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
            child: Text(
              items[i].$1,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ts(c: i == items.length - 1 ? tk.text : tk.sec, w: i == items.length - 1 ? FontWeight.w600 : null),
            ),
          ),
        ),
      ),
    ],
  ],
);

// ---------------- shared layout ----------------

/// The cover's width on a book or series page: big on a PC, about a third of
/// the screen on a phone (like Tachiyomi's).
double _coverW(double w) => isPhone ? (w * 0.36).clamp(110.0, 190.0) : (w >= 1300 ? 300.0 : 240.0);

/// Covers are 2:3 (1.5 times as tall as wide) everywhere.
const coverAspect = 2 / 3;

Widget _coverBox(Book b, double w, {double? progress, String? coverKey, String? pos}) => ClipRRect(
  borderRadius: BorderRadius.circular(lk.rPanel),
  child: SizedBox(
    width: w,
    height: w * 1.5,
    child: Stack(
      children: [
        Positioned.fill(
          child: BookCover(book: b, width: w, coverKey: coverKey, pos: pos),
        ),
        if (progress != null) Positioned(left: 0, right: 0, bottom: 0, child: ProgressLine(value: progress)),
      ],
    ),
  ),
);

/// The top of a book or series page: back, then where you are.
Widget _topNav(List<(String, VoidCallback?)> items) =>
    Padding(padding: isPhone ? const EdgeInsets.fromLTRB(4, 2, 12, 0) : const EdgeInsets.fromLTRB(12, 10, 16, 4), child: _crumbs(items));

EdgeInsets get _pagePad => isPhone ? const EdgeInsets.fromLTRB(12, 6, 12, 20) : const EdgeInsets.fromLTRB(24, 12, 24, 24);

Widget _description(BuildContext context, String? text, {required VoidCallback onEdit, VoidCallback? onFind}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text('Description', style: ts(w: FontWeight.w700)),
          const Spacer(),
          if (onFind != null) Btn.ghost('Find online', icon: Icons.travel_explore, dense: true, onTap: onFind),
          Btn.ghost(text == null ? 'Add' : 'Edit', icon: Icons.edit_note, dense: true, onTap: onEdit),
        ],
      ),
      const SizedBox(height: 4),
      if (text == null)
        Text('No description yet.', style: ts(c: tk.faint))
      else
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: SelectableText(text, style: ts(c: tk.sec, size: 13.5).copyWith(height: 1.55)),
        ),
    ],
  );
}

String _readLabel(Volume v) => v.isRead ? 'Read again' : (v.inProgress ? 'Continue · ${(v.progress * 100).floor()}%' : 'Read');

// ---------------- one book ----------------

class BookPage extends StatelessWidget {
  const BookPage({super.key, required this.volumeKey});
  final String volumeKey;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Library.I, Covers.I, Downloads.I, Jobs.I]),
      builder: (context, _) {
        final v = Library.I.volumes[volumeKey];
        if (v == null) {
          return EmptyState(
            icon: Icons.search_off,
            text: 'This book isn\'t in the library any more.',
            action: Btn('Back', onTap: Nav.I.closeDetail),
          );
        }
        final b = v.primary;
        final series = Library.I.seriesOf(b);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _topNav([
              ('Library', Nav.I.closeDetail),
              if (series != null) (b.displaySeries ?? '', () => Nav.I.openSeriesKey(b.seriesKey)),
              (series != null && b.volumeText.isNotEmpty ? b.volumeText : b.displayTitle, null),
            ]),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => Smooth(
                  builder: (sc) => SingleChildScrollView(
                    controller: sc,
                    padding: _pagePad,
                    child: isPhone ? _phone(context, v, box.maxWidth) : _pc(context, v, box.maxWidth),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _changeCover(BuildContext context, Volume v) async {
    final b = v.primary;
    final what = await coverMenu(context, custom: b.userCover != null);
    if (what == null || !context.mounted) return;
    switch (what) {
      case CoverAction.find:
        final k = await findCoverDialog(context, title: b.displayTitle, author: b.displayAuthor);
        if (k != null) {
          Library.I.setCover(v, k);
          Library.I.setCoverPos(v, null);
        }
      case CoverAction.change:
        final k = await coverDialog(context, 'Cover for ${b.displayTitle}');
        if (k != null) {
          Library.I.setCover(v, k.isEmpty ? null : k);
          Library.I.setCoverPos(v, null);
        }
      case CoverAction.frame:
        final f = Covers.I.cached(b);
        if (f == null) {
          toast('This book has no cover picture to frame yet.', ToastKind.info);
          return;
        }
        final pos = await reframeDialog(context, file: f, pos: b.coverPos);
        if (pos != null) Library.I.setCoverPos(v, pos.isEmpty ? null : pos);
      case CoverAction.reset:
        Library.I.setCover(v, null);
        Library.I.setCoverPos(v, null);
    }
  }

  Future<void> _findDescription(BuildContext context, Volume v) async {
    final b = v.primary;
    final t = await findDescriptionDialog(context, title: b.displayTitle, author: b.displayAuthor);
    if (t != null) Library.I.setFoundDescription(v, t);
  }

  Future<void> _editDescription(BuildContext context, Volume v) async {
    final t = await descriptionDialog(context, 'Description', v.primary.shownDescription);
    if (t != null) Library.I.setDescription(v, t);
  }

  Widget _pc(BuildContext context, Volume v, double w) {
    final b = v.primary;
    final cw = _coverW(w);
    final twoCols = w - cw - 28 >= 900;
    final colA = _main(context, v);
    final colB = _side(context, v);
    return _Cols(
      coverW: cw,
      wide: twoCols,
      cover: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _coverBox(b, cw, progress: v.progress),
          const SizedBox(height: 12),
          Btn.primary(_readLabel(v), icon: Icons.auto_stories, big: true, onTap: () => openBook(context, b)),
          for (final f in v.formats.where((x) => x.format != b.format))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Btn('Read the ${f.format.toUpperCase()}', icon: Icons.description_outlined, onTap: () => openBook(context, f)),
            ),
          const SizedBox(height: 6),
          Btn.ghost('Show in folder', icon: Icons.folder_open_outlined, onTap: () => showInFolder(b)),
        ],
      ),
      main: colA,
      side: colB,
    );
  }

  Widget _phone(BuildContext context, Volume v, double w) {
    final b = v.primary;
    final cw = _coverW(w);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _coverBox(b, cw, progress: v.progress),
            const SizedBox(width: 14),
            Expanded(child: _head(context, v, compact: true)),
          ],
        ),
        const SizedBox(height: 14),
        Btn.primary(_readLabel(v), icon: Icons.auto_stories, big: true, onTap: () => openBook(context, b)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            DownloadBtn(b),
            for (final f in v.formats.where((x) => x.format != b.format))
              Btn('Read the ${f.format.toUpperCase()}', icon: Icons.description_outlined, onTap: () => openBook(context, f)),
          ],
        ),
        const SizedBox(height: 12),
        _actions(context, v),
        const SizedBox(height: 16),
        _description(context, b.shownDescription, onEdit: () => _editDescription(context, v)),
        const SizedBox(height: 18),
        _side(context, v),
      ],
    );
  }

  /// Series, title, author, kind and length, rating and favourite.
  Widget _head(BuildContext context, Volume v, {bool compact = false}) {
    final b = v.primary;
    final len = lengthText(b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (b.inSeries && b.displaySeries != null)
          Text(
            '${b.displaySeries}${b.volumeText.isEmpty ? '' : ' · ${b.volumeText}'}${b.edition.isEmpty ? '' : ' · ${b.edition}'}',
            style: ts(c: lk.acc, w: FontWeight.w600, size: compact ? 12.5 : null),
          ),
        const SizedBox(height: 4),
        SelectableText(
          b.displayTitle,
          style: ts(size: compact ? 18 : 24, w: FontWeight.w700),
        ),
        if (b.displayAuthor != null) ...[
          const SizedBox(height: 4),
          Text(
            b.displayAuthor!,
            style: ts(size: compact ? 13 : 14, c: tk.sec),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _chip(b.displayKind.label),
            for (final f in v.formats) _chip(f.format.toUpperCase() + (isInZip(f.path) ? ' in ZIP' : '')),
            if (b.collection) _chip('Collection'),
            if (len.isNotEmpty)
              Text(
                len,
                style: ts(c: tk.faint, size: compact ? 12 : null),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Stars(value: v.rating, size: compact ? 20 : 24, onChanged: (r) => Library.I.setRating(v, r)),
            const SizedBox(width: 8),
            IconBtn(
              v.favourite ? Icons.favorite : Icons.favorite_border,
              tooltip: v.favourite ? 'Favourite' : 'Add to favourites',
              color: v.favourite ? const Color(0xFFFF6FB1) : null,
              onTap: () => Library.I.toggleFavourite([v]),
            ),
            TagMenu(volumes: [v]),
          ],
        ),
      ],
    );
  }

  Widget _actions(BuildContext context, Volume v) {
    final series = Library.I.seriesOf(v.primary);
    final tags = Library.I.tagsOfVolume(v).map(Library.I.tagById).whereType<Tag>().toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Btn(
              v.isRead ? 'Mark unread' : 'Mark read',
              icon: v.isRead ? Icons.remove_done : Icons.done_all,
              dense: true,
              onTap: () => Library.I.markRead([v], !v.isRead),
            ),
            if (series != null && Library.I.previousVolumes(v).any((x) => !x.isRead))
              Btn(
                'Mark previous as read',
                dense: true,
                onTap: () {
                  final prev = Library.I.previousVolumes(v);
                  Library.I.markRead(prev, true);
                  toast('Marked ${prev.length} earlier volumes read');
                },
              ),
            Btn('Edit details', icon: Icons.edit_outlined, dense: true, onTap: () => editDetails(context, v.primary)),
            if (!isPhone) Btn('Cover', icon: Icons.image_outlined, dense: true, onTap: () => _changeCover(context, v)),
          ],
        ),
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in tags) TagChip(t.name, Color(t.color), onRemove: () => Library.I.removeTag(t, [v])),
            ],
          ),
        ],
      ],
    );
  }

  Widget _main(BuildContext context, Volume v) {
    final b = v.primary;
    final busy = Jobs.I.isQueued(Lookup.jobName);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _head(context, v),
        const SizedBox(height: 14),
        _actions(context, v),
        const SizedBox(height: 18),
        _description(
          context,
          b.shownDescription,
          onEdit: () => _editDescription(context, v),
          onFind: busy ? null : () => _findDescription(context, v),
        ),
        if (v.hasCopies) ...[const SizedBox(height: 18), CopiesBox(volume: v, onRead: (f) => openBook(context, f))],
      ],
    );
  }

  /// The book's details and its reading history.
  Widget _side(BuildContext context, Volume v) {
    final sessions = [for (final f in v.files) ...Db.I.sessions(bookId: f.id)]..sort((a, c) => c.startedAt.compareTo(a.startedAt));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isPhone && v.hasCopies) ...[CopiesBox(volume: v, onRead: (f) => openBook(context, f)), const SizedBox(height: 16)],
        _details(v),
        const SizedBox(height: 18),
        Text('Reading history', style: ts(w: FontWeight.w700)),
        const SizedBox(height: 6),
        if (sessions.isEmpty)
          Text('Not read in Sable yet.', style: ts(c: tk.faint))
        else
          for (final s in sessions.take(40))
            Container(
              padding: const EdgeInsets.symmetric(vertical: 5),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: tk.line.withValues(alpha: 0.5))),
              ),
              child: Wrap(
                spacing: 10,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('${dateText(s.startedAt)} ${timeText(s.startedAt)}', style: ts(c: tk.sec, tab: true)),
                  Text(formatDuration(Duration(seconds: s.activeSeconds)), style: ts(tab: true)),
                  Text('${(s.fromPct * 100).floor()}% → ${(s.toPct * 100).floor()}%', style: ts(c: tk.sec, tab: true)),
                  if (s.device != 'PC') Text(s.device, style: ts(c: tk.faint, size: 12)),
                  if (s.completed)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle, size: 14, color: tk.ok),
                        const SizedBox(width: 4),
                        Text('Finished', style: ts(c: tk.ok, size: 12)),
                      ],
                    ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _chip(String s) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: tk.raised,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: tk.line),
    ),
    child: Text(
      s,
      style: ts(size: 11.5, c: tk.sec, w: FontWeight.w600),
    ),
  );

  Widget _details(Volume v) {
    final b = v.primary;
    final rows = <(String, String)>[
      if (b.publisher != null) ('Publisher', b.publisher!),
      if (b.published != null) ('Published', b.published!.length > 10 ? b.published!.substring(0, 10) : b.published!),
      if (b.language != null) ('Language', b.language!),
      ('Added', dateText(v.addedAt)),
      if (v.readCount > 0) ('Times read', '${v.readCount}'),
      if (v.firstCompletedAt > 0) ('First finished', dateText(v.firstCompletedAt)),
      if (v.lastCompletedAt > 0 && v.lastCompletedAt != v.firstCompletedAt) ('Last finished', dateText(v.lastCompletedAt)),
      if (v.timeSpent > 0) ('Time spent', humanHours(v.timeSpent)),
      for (final f in v.files) ('File', f.path.replaceAll(zipSep, '  ›  ')),
    ];
    return PanelBox(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: isPhone
                  // A phone: the name above its value, so long values fit.
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.$1, style: ts(c: tk.faint, size: 12)),
                        SelectableText(
                          r.$2,
                          style: ts(c: tk.sec, mono: r.$1 == 'File', size: r.$1 == 'File' ? 11.5 : 13),
                        ),
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 120,
                          child: Text(r.$1, style: ts(c: tk.faint)),
                        ),
                        Expanded(
                          child: SelectableText(
                            r.$2,
                            style: ts(c: tk.sec, mono: r.$1 == 'File', size: r.$1 == 'File' ? 12 : null),
                          ),
                        ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}

Future<void> editDetails(BuildContext context, Book b) async {
  final title = TextEditingController(text: b.displayTitle);
  final author = TextEditingController(text: b.displayAuthor ?? '');
  final series = TextEditingController(text: b.displaySeries ?? '');
  final vol = TextEditingController(text: b.displayVolume == null ? '' : volumeLabel(b.displayVolume!));
  var kind = b.displayKind;
  final ok = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black54,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AppDialog(
        title: 'Edit details',
        width: 700,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your changes are kept even when the library is scanned again. Clear a box to go back to what the file says.',
              style: ts(c: tk.sec),
            ),
            const SizedBox(height: 12),
            for (final (l, ctl) in [('Title', title), ('Author', author), ('Series', series), ('Volume', vol)])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 70,
                      child: Text(l, style: ts(c: tk.sec)),
                    ),
                    Expanded(child: Field(controller: ctl)),
                  ],
                ),
              ),
            Row(
              children: [
                SizedBox(
                  width: 70,
                  child: Text('Type', style: ts(c: tk.sec)),
                ),
                Seg<Kind>(value: kind, items: [for (final k in Kind.values) (k, k.label)], onChanged: (k) => set(() => kind = k)),
              ],
            ),
          ],
        ),
        actions: [
          Btn('Cancel', onTap: () => Navigator.pop(c, false)),
          Btn.primary('Save', onTap: () => Navigator.pop(c, true)),
        ],
      ),
    ),
  );
  if (ok != true) return;
  // What the file and folders say, without hand edits.
  b
    ..userTitle = null
    ..userAuthor = null
    ..userSeries = null
    ..userVolume = null
    ..userKind = null;
  String? keep(TextEditingController c, String? auto) {
    final t = c.text.trim();
    return t.isEmpty || t == (auto ?? '') ? null : t;
  }

  final autoVol = b.displayVolume;
  b
    ..userTitle = keep(title, b.displayTitle)
    ..userAuthor = keep(author, b.displayAuthor)
    ..userSeries = keep(series, b.displaySeries);
  final vn = double.tryParse(vol.text.trim());
  b.userVolume = vn == null || vn == autoVol ? null : vn;
  b.userKind = kind == b.kind ? null : kind.name;
  Library.I.saveEdits(b);
  // The book may now belong to another volume or series.
  Nav.I.openVolume(Library.I.volumeOf(b) ?? Volume(b.volumeKey, [b]));
  toast('Details saved');
}

// ---------------- a series ----------------

class SeriesPage extends StatefulWidget {
  const SeriesPage({super.key, required this.seriesKey});
  final String seriesKey;
  @override
  State<SeriesPage> createState() => _SeriesPageState();
}

class _SeriesPageState extends State<SeriesPage> {
  String? edition;
  final Set<String> ticked = {};

  /// Picking books (the Select button) instead of opening them.
  bool selecting = false;

  void _toggle(Volume v) => setState(() => ticked.contains(v.key) ? ticked.remove(v.key) : ticked.add(v.key));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Library.I, Covers.I, Downloads.I, Jobs.I]),
      builder: (context, _) {
        final all = Library.I.series[widget.seriesKey];
        if (all == null || all.isEmpty) {
          return EmptyState(
            icon: Icons.search_off,
            text: 'This series isn\'t in the library any more.',
            action: Btn('Back', onTap: Nav.I.closeDetail),
          );
        }
        final editions = all.map((v) => v.any.edition).toSet().toList()..sort();
        edition ??= editions.first;
        if (!editions.contains(edition)) edition = editions.first;
        final vols = all.where((v) => v.any.edition == edition).toList();
        final first = vols.first.any;
        final entry = SeriesEntry(widget.seriesKey, first.displaySeries ?? '', vols);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _topNav([('Library', Nav.I.closeDetail), (entry.label, null)]),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => Smooth(
                  builder: (sc) => SingleChildScrollView(
                    controller: sc,
                    padding: _pagePad,
                    child: isPhone ? _phone(context, entry, editions, box.maxWidth) : _pc(context, entry, editions, box.maxWidth),
                  ),
                ),
              ),
            ),
            if (ticked.isNotEmpty) _selectionBar(vols),
          ],
        );
      },
    );
  }

  SeriesInfo get _info => Library.I.infoFor(widget.seriesKey);

  void _saveCover(String? key, String? pos) {
    final i = _info
      ..cover = key
      ..coverPos = pos;
    Library.I.saveInfo(i);
    Covers.I.version++;
    Covers.I.changedNow();
  }

  Future<void> _changeCover(SeriesEntry e) async {
    final what = await coverMenu(context, custom: _info.cover != null);
    if (what == null || !mounted) return;
    switch (what) {
      case CoverAction.find:
        final k = await findCoverDialog(context, title: e.label, author: e.volumes.first.any.displayAuthor);
        if (k != null) _saveCover(k, null);
      case CoverAction.change:
        final k = await coverDialog(context, 'Cover for the series', canReset: _info.cover != null);
        if (k != null) _saveCover(k.isEmpty ? null : k, null);
      case CoverAction.frame:
        // Framing a series that uses its first book's cover makes that its own.
        final key = _info.cover ?? Covers.I.keyFor(e.volumes.first.any);
        final f = File(Covers.I.fileForFp(key));
        if (!f.existsSync()) {
          toast('This series has no cover picture to frame yet.', ToastKind.info);
          return;
        }
        final pos = await reframeDialog(context, file: f, pos: _info.coverPos);
        if (pos != null) _saveCover(key, pos.isEmpty ? null : pos);
      case CoverAction.reset:
        _saveCover(null, null);
    }
  }

  Future<void> _findDescription(SeriesEntry e) async {
    final t = await findDescriptionDialog(context, title: e.label, author: e.volumes.first.any.displayAuthor);
    if (t == null) return;
    final i = _info..foundDescription = t;
    Library.I.saveInfo(i);
  }

  Future<void> _editDescription() async {
    final t = await descriptionDialog(context, 'Series description', _info.shownDescription);
    if (t == null) return;
    final i = _info..description = t.trim().isEmpty ? null : t.trim();
    Library.I.saveInfo(i);
  }

  Widget _readBtn(SeriesEntry e) {
    final vols = e.volumes;
    final next = e.next;
    final readN = e.readCount;
    return Btn.primary(
      next.inProgress
          ? 'Continue ${next.any.volumeText} · ${(next.progress * 100).floor()}%'
          : (readN == vols.length ? 'Read again from ${vols.first.any.volumeText}' : 'Read ${next.any.volumeText}'),
      icon: Icons.auto_stories,
      big: true,
      onTap: () => openBook(context, next.primary),
    );
  }

  Widget _head(SeriesEntry e, List<String> editions, {bool compact = false}) {
    final vols = e.volumes;
    final readN = e.readCount;
    final authors = vols.map((v) => v.any.displayAuthor).whereType<String>().toSet();
    final time = vols.fold<int>(0, (a, v) => a + v.any.minutes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          e.label,
          style: ts(size: compact ? 18 : 24, w: FontWeight.w700),
        ),
        if (authors.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            authors.take(2).join(', '),
            style: ts(c: tk.sec, size: compact ? 13 : 14),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          '${vols.length} volumes · $readN read${time > 0 ? ' · about ${(time / 60).round()} h of reading' : ''}',
          style: ts(c: tk.faint, size: compact ? 12.5 : null),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: compact ? null : 360,
          child: Progress(value: vols.isEmpty ? 0 : readN / vols.length, height: compact ? 4 : 5),
        ),
        const SizedBox(height: 6),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconBtn(
              vols.every((v) => v.favourite) ? Icons.favorite : Icons.favorite_border,
              tooltip: 'Favourite every volume',
              color: vols.every((v) => v.favourite) ? const Color(0xFFFF6FB1) : null,
              onTap: () => Library.I.toggleFavourite(vols),
            ),
            TagMenu(volumes: vols),
          ],
        ),
        if (editions.length > 1) ...[
          const SizedBox(height: 6),
          Seg<String>(
            value: edition!,
            items: [for (final x in editions) (x, x.isEmpty ? 'Light novel' : x)],
            onChanged: (x) => setState(() {
              edition = x;
              ticked.clear();
            }),
          ),
        ],
      ],
    );
  }

  Widget _actions(SeriesEntry e) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      Btn(
        selecting ? 'Done selecting' : 'Select',
        icon: selecting ? Icons.check : Icons.checklist,
        dense: true,
        onTap: () => setState(() {
          selecting = !selecting;
          if (!selecting) ticked.clear();
        }),
      ),
      Btn(
        'Edit series',
        icon: Icons.edit_outlined,
        dense: true,
        onTap: () async {
          final k = await seriesDialog(context, name: e.label, volumes: e.volumes);
          // A new name is a new key: stay on the series under its new name.
          if (k != null && k != widget.seriesKey) Nav.I.replaceSeriesKey(k);
        },
      ),
      if (!isPhone) Btn('Cover', icon: Icons.image_outlined, dense: true, onTap: () => _changeCover(e)),
    ],
  );

  Widget _desc(SeriesEntry e) => _description(
    context,
    _info.shownDescription,
    onEdit: _editDescription,
    onFind: isPhone || Jobs.I.isQueued(Lookup.jobName) ? null : () => _findDescription(e),
  );

  Widget _pc(BuildContext context, SeriesEntry e, List<String> editions, double w) {
    final cw = _coverW(w);
    final twoCols = w - cw - 28 >= 900;
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_head(e, editions), const SizedBox(height: 12), _actions(e), const SizedBox(height: 18), _desc(e)],
    );
    final books = _books(e);
    return _Cols(
      coverW: cw,
      wide: twoCols,
      flexMain: 9,
      flexSide: 11,
      cover: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _coverBox(e.volumes.first.any, cw, coverKey: _info.cover, pos: _info.coverPos),
          const SizedBox(height: 12),
          _readBtn(e),
        ],
      ),
      main: info,
      side: books,
    );
  }

  Widget _phone(BuildContext context, SeriesEntry e, List<String> editions, double w) {
    final cw = _coverW(w);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _coverBox(e.volumes.first.any, cw, coverKey: _info.cover, pos: _info.coverPos),
            const SizedBox(width: 14),
            Expanded(child: _head(e, editions, compact: true)),
          ],
        ),
        const SizedBox(height: 14),
        _readBtn(e),
        const SizedBox(height: 8),
        SeriesDownloads(e.volumes),
        const SizedBox(height: 10),
        _actions(e),
        const SizedBox(height: 16),
        _desc(e),
        const SizedBox(height: 16),
        _books(e),
      ],
    );
  }

  Widget _books(SeriesEntry e) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Books', style: ts(w: FontWeight.w700)),
      const SizedBox(height: 6),
      for (final v in e.volumes) _row(context, v, e.volumes),
    ],
  );

  Widget _selectionBar(List<Volume> vols) {
    final sel = vols.where((v) => ticked.contains(v.key)).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      decoration: BoxDecoration(
        color: tk.panel,
        border: Border(top: BorderSide(color: tk.line)),
      ),
      child: Smooth(
        builder: (sc) => SingleChildScrollView(
          controller: sc,
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              Text('${sel.length} selected', style: ts(w: FontWeight.w600)),
              const SizedBox(width: 10),
              if (isPhone) ...[
                Btn(
                  'Download',
                  dense: true,
                  icon: Icons.download_outlined,
                  onTap: () {
                    Downloads.I.add(sel.map((v) => v.primary));
                    setState(ticked.clear);
                  },
                ),
                const SizedBox(width: 6),
              ],
              Btn('Mark read', dense: true, icon: Icons.done_all, onTap: () => Library.I.markRead(sel, true)),
              const SizedBox(width: 6),
              Btn('Mark unread', dense: true, icon: Icons.remove_done, onTap: () => Library.I.markRead(sel, false)),
              const SizedBox(width: 6),
              TagMenu(volumes: sel),
              if (!isPhone) ...[
                const SizedBox(width: 6),
                Btn(
                  'Find descriptions',
                  dense: true,
                  icon: Icons.travel_explore,
                  onTap: () => Lookup.run(volumes: sel),
                ),
                if (sel.length >= 2) ...[
                  const SizedBox(width: 6),
                  Btn(
                    'Combine as one book',
                    dense: true,
                    icon: Icons.merge,
                    onTap: () {
                      Library.I.combine(sel);
                      setState(ticked.clear);
                    },
                  ),
                ],
              ],
              const SizedBox(width: 12),
              Btn.ghost('Clear', dense: true, onTap: () => setState(ticked.clear)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, Volume v, List<Volume> vols) {
    final b = v.primary;
    final on = ticked.contains(v.key);
    final sub = b.subtitle ?? (b.metaTitle != null && normKey(b.metaTitle!) != normKey(b.displaySeries ?? '') ? b.displayTitle : '');
    const cw = 56.0;
    return Hoverable(
      builder: (h) => GestureDetector(
        onTap: () {
          if (selecting || HardwareKeyboard.instance.isControlPressed || ticked.isNotEmpty) {
            _toggle(v);
          } else {
            Nav.I.openVolume(v);
          }
        },
        onDoubleTap: isPhone ? null : () => openBook(context, b),
        onLongPress: () => setState(() {
          selecting = true;
          _toggle(v);
        }),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            color: on ? lk.tint(tk.ground, 0.17) : (h ? tk.raised : null),
            borderRadius: BorderRadius.circular(lk.rControl),
            border: Border.all(color: on ? lk.acc.withValues(alpha: 0.6) : Colors.transparent),
          ),
          child: Row(
            children: [
              if (selecting) ...[
                Icon(on ? Icons.check_circle : Icons.radio_button_unchecked, size: 20, color: on ? lk.acc : tk.faint),
                const SizedBox(width: 8),
              ],
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: isPhone ? 50 : cw,
                  height: (isPhone ? 50 : cw) * 1.5,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: BookCover(book: b, width: cw),
                      ),
                      Positioned(left: 0, right: 0, bottom: 0, child: ProgressLine(value: v.progress)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      b.volumeText.isEmpty ? b.displayTitle : b.volumeText,
                      style: ts(w: FontWeight.w600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (sub.isNotEmpty)
                      Text(
                        sub,
                        style: ts(c: tk.sec, size: 12),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        v.formats.map((f) => f.format.toUpperCase()).join(' '),
                        lengthText(b).split(' · ').first,
                      ].where((x) => x.isNotEmpty).join(' · '),
                      style: ts(c: tk.faint, size: 11.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (v.rating > 0 && !isPhone) ...[Stars(value: v.rating, size: 12), const SizedBox(width: 8)],
              if (v.isRead)
                Icon(Icons.check_circle, size: 16, color: tk.ok)
              else if (v.inProgress)
                Text(
                  '${(v.progress * 100).floor()}%',
                  style: ts(c: lk.acc, w: FontWeight.w600, tab: true),
                ),
              if (isPhone && Downloads.I.isQueued(b)) ...[const SizedBox(width: 8), Icon(Icons.downloading, size: 16, color: lk.acc)],
              // Read straight from the list.
              if (!selecting && (!isPhone || Downloads.I.isDone(b))) ...[
                const SizedBox(width: 10),
                Btn(
                  v.inProgress ? 'Continue' : (v.isRead ? 'Read again' : 'Read'),
                  icon: Icons.auto_stories,
                  dense: true,
                  onTap: () => openBook(context, b),
                ),
              ],
              PopupMenuButton<String>(
                tooltip: '',
                icon: Icon(Icons.more_horiz, size: 18, color: tk.sec),
                onSelected: (k) {
                  switch (k) {
                    case 'read':
                      openBook(context, b);
                    case 'mark':
                      Library.I.markRead([v], !v.isRead);
                    case 'prev':
                      final prev = Library.I.previousVolumes(v);
                      Library.I.markRead([...prev, v], true);
                      toast('Marked ${prev.length + 1} volumes read');
                    case 'folder':
                      showInFolder(b);
                    case 'download':
                      Downloads.I.add([b]);
                    case 'remove':
                      Downloads.I.remove([b]);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'read',
                    child: Text('Read', style: ts()),
                  ),
                  PopupMenuItem(
                    value: 'mark',
                    child: Text(v.isRead ? 'Mark unread' : 'Mark read', style: ts()),
                  ),
                  PopupMenuItem(
                    value: 'prev',
                    child: Text('Mark this and earlier volumes read', style: ts()),
                  ),
                  if (!isPhone)
                    PopupMenuItem(
                      value: 'folder',
                      child: Text('Show in folder', style: ts()),
                    ),
                  if (isPhone && !Downloads.I.isDone(b) && !Downloads.I.isQueued(b))
                    PopupMenuItem(
                      value: 'download',
                      child: Text('Download (${humanSize(b.size)})', style: ts()),
                    ),
                  if (isPhone && Downloads.I.isDone(b))
                    PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove from this phone', style: ts()),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
