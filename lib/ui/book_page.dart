import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../core/books.dart';
import '../core/db.dart';
import '../core/jobs.dart';
import '../core/library.dart';
import '../core/parse.dart';
import '../core/downloads.dart';
import '../core/platform.dart';
import '../core/settings.dart';
import 'app.dart';
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

Widget _crumbs(List<(String, VoidCallback?)> items) => Row(children: [
      IconBtn(Icons.arrow_back, tooltip: 'Back (Esc or the mouse\'s back button)', onTap: () {
        if (Nav.I.canGoBack) {
          Nav.I.back();
        } else {
          Nav.I.closeDetail();
        }
      }),
      const SizedBox(width: 6),
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) Icon(Icons.chevron_right, size: 16, color: tk.faint),
        Flexible(
          child: GestureDetector(
            onTap: items[i].$2,
            child: MouseRegion(
              cursor: items[i].$2 == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
              child: Text(items[i].$1,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts(c: i == items.length - 1 ? tk.text : tk.sec, w: i == items.length - 1 ? FontWeight.w600 : null)),
            ),
          ),
        ),
      ],
    ]);

// ---------------- one book ----------------

class BookPage extends StatelessWidget {
  const BookPage({super.key, required this.volumeKey});
  final String volumeKey;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Library.I, Covers.I]),
      builder: (context, _) {
        final v = Library.I.volumes[volumeKey];
        if (v == null) {
          return EmptyState(icon: Icons.search_off, text: 'This book isn\'t in the library any more.', action: Btn('Back', onTap: Nav.I.closeDetail));
        }
        final b = v.primary;
        final series = Library.I.seriesOf(b);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 16, 4),
            child: _crumbs([
              ('Library', Nav.I.closeDetail),
              if (series != null)
                (b.displaySeries ?? '', () => Nav.I.openSeriesKey(b.seriesKey)),
              (series != null && b.volumeText.isNotEmpty ? b.volumeText : b.displayTitle, null),
            ]),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: isPhone ? const EdgeInsets.fromLTRB(14, 8, 14, 24) : const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: isPhone && MediaQuery.sizeOf(context).width < 620
                  // A phone: the cover and buttons above the details.
                  ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Center(child: _left(context, v)),
                      const SizedBox(height: 18),
                      _right(context, v),
                    ])
                  : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      _left(context, v),
                      const SizedBox(width: 28),
                      Expanded(child: _right(context, v)),
                    ]),
            ),
          ),
        ]);
      },
    );
  }

  Widget _left(BuildContext context, Volume v) {
    final b = v.primary;
    final label = v.isRead ? 'Read again' : (v.inProgress ? 'Continue · ${(v.progress * 100).floor()}%' : 'Read');
    return SizedBox(
      width: isPhone ? 200 : 230,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(lk.rPanel),
          child: AspectRatio(
            aspectRatio: 2 / 3,
            child: Stack(children: [
              Positioned.fill(child: BookCover(book: b, width: 230)),
              Positioned(left: 0, right: 0, bottom: 0, child: ProgressLine(value: v.progress)),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Btn.primary(label, icon: Icons.auto_stories, onTap: () => openBook(context, b)),
        if (v.formats.length > 1) ...[
          const SizedBox(height: 8),
          for (final f in v.formats.where((x) => x.format != b.format))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Btn('Open as ${f.format.toUpperCase()}', icon: Icons.description_outlined, onTap: () => openBook(context, f)),
            ),
        ],
        const SizedBox(height: 4),
        if (isPhone)
          DownloadBtn(b)
        else
          Btn.ghost('Show in folder', icon: Icons.folder_open_outlined, onTap: () => showInFolder(b)),
      ]),
    );
  }

  Widget _right(BuildContext context, Volume v) {
    final b = v.primary;
    final tags = Library.I.tagsOfVolume(v).map(Library.I.tagById).whereType<Tag>().toList();
    final series = Library.I.seriesOf(b);
    final len = lengthText(b);
    final sessions = [for (final f in v.files) ...Db.I.sessions(bookId: f.id)]..sort((a, c) => c.startedAt.compareTo(a.startedAt));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (b.inSeries && b.displaySeries != null)
        Text('${b.displaySeries}${b.volumeText.isEmpty ? '' : ' · ${b.volumeText}'}${b.edition.isEmpty ? '' : ' · ${b.edition}'}',
            style: ts(c: lk.acc, w: FontWeight.w600)),
      const SizedBox(height: 4),
      SelectableText(b.displayTitle, style: ts(size: 24, w: FontWeight.w700)),
      if (b.displayAuthor != null) ...[
        const SizedBox(height: 4),
        Text(b.displayAuthor!, style: ts(size: 14, c: tk.sec)),
      ],
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        _chip(b.displayKind.label),
        for (final f in v.formats) _chip(f.format.toUpperCase() + (isInZip(f.path) ? ' in ZIP' : '')),
        if (len.isNotEmpty) Text(len, style: ts(c: tk.faint)),
        if (b.collection) _chip('Collection'),
      ]),
      const SizedBox(height: 16),
      Wrap(spacing: 0, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Stars(value: v.rating, size: 24, onChanged: (r) => Library.I.setRating(v, r)),
        const SizedBox(width: 14),
        IconBtn(v.favourite ? Icons.favorite : Icons.favorite_border,
            tooltip: v.favourite ? 'Favourite' : 'Add to favourites', color: v.favourite ? const Color(0xFFFF6FB1) : null, onTap: () => Library.I.toggleFavourite([v])),
        const SizedBox(width: 8),
        TagMenu(volumes: [v]),
        const SizedBox(width: 8),
        Btn(v.isRead ? 'Mark unread' : 'Mark read', icon: v.isRead ? Icons.remove_done : Icons.done_all, dense: true,
            onTap: () => Library.I.markRead([v], !v.isRead)),
        if (series != null && Library.I.previousVolumes(v).any((x) => !x.isRead)) ...[
          const SizedBox(width: 8),
          Btn('Mark previous as read', dense: true, onTap: () {
            final prev = Library.I.previousVolumes(v);
            Library.I.markRead(prev, true);
            toast('Marked ${prev.length} earlier volumes read');
          }),
        ],
        const SizedBox(width: 8),
        Btn.ghost('Edit details', icon: Icons.edit_outlined, dense: true, onTap: () => editDetails(context, b)),
      ]),
      if (tags.isNotEmpty) ...[
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final t in tags) TagChip(t.name, Color(t.color), onRemove: () => Library.I.removeTag(t, [v])),
        ]),
      ],
      if ((b.description ?? '').isNotEmpty) ...[
        const SizedBox(height: 18),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: SelectableText(b.description!, style: ts(c: tk.sec, size: 13.5).copyWith(height: 1.55)),
        ),
      ],
      const SizedBox(height: 20),
      _details(v),
      const SizedBox(height: 20),
      Text('Reading history', style: ts(w: FontWeight.w700)),
      const SizedBox(height: 8),
      if (sessions.isEmpty)
        Text('Not read in Sable yet.', style: ts(c: tk.faint))
      else
        for (final s in sessions.take(40))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              SizedBox(width: 120, child: Text(dateText(s.startedAt), style: ts(c: tk.sec))),
              SizedBox(width: 60, child: Text(timeText(s.startedAt), style: ts(c: tk.faint, tab: true))),
              SizedBox(width: 90, child: Text(formatDuration(Duration(seconds: s.activeSeconds)), style: ts(tab: true))),
              Text('${(s.fromPct * 100).floor()}% → ${(s.toPct * 100).floor()}%', style: ts(c: tk.sec, tab: true)),
              if (s.completed) ...[const SizedBox(width: 10), Icon(Icons.check_circle, size: 14, color: tk.ok), const SizedBox(width: 4), Text('Finished', style: ts(c: tk.ok, size: 12))],
            ]),
          ),
    ]);
  }

  Widget _chip(String s) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: tk.raised, borderRadius: BorderRadius.circular(10), border: Border.all(color: tk.line)),
        child: Text(s, style: ts(size: 11.5, c: tk.sec, w: FontWeight.w600)),
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
      child: Column(children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 120, child: Text(r.$1, style: ts(c: tk.faint))),
              Expanded(child: SelectableText(r.$2, style: ts(c: tk.sec, mono: r.$1 == 'File', size: r.$1 == 'File' ? 12 : null))),
            ]),
          ),
      ]),
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
        width: 520,
        body: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Your changes are kept even when the library is scanned again. Clear a box to go back to what the file says.',
              style: ts(c: tk.sec)),
          const SizedBox(height: 12),
          for (final (l, ctl) in [('Title', title), ('Author', author), ('Series', series), ('Volume', vol)])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                SizedBox(width: 70, child: Text(l, style: ts(c: tk.sec))),
                Expanded(child: Field(controller: ctl)),
              ]),
            ),
          Row(children: [
            SizedBox(width: 70, child: Text('Type', style: ts(c: tk.sec))),
            Seg<Kind>(value: kind, items: [for (final k in Kind.values) (k, k.label)], onChanged: (k) => set(() => kind = k)),
          ]),
        ]),
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Library.I, Covers.I, Downloads.I]),
      builder: (context, _) {
        final all = Library.I.series[widget.seriesKey];
        if (all == null || all.isEmpty) {
          return EmptyState(icon: Icons.search_off, text: 'This series isn\'t in the library any more.', action: Btn('Back', onTap: Nav.I.closeDetail));
        }
        final editions = all.map((v) => v.any.edition).toSet().toList()..sort();
        edition ??= editions.first;
        if (!editions.contains(edition)) edition = editions.first;
        final vols = all.where((v) => v.any.edition == edition).toList();
        final first = vols.first.any;
        final entry = SeriesEntry(widget.seriesKey, first.displaySeries ?? '', vols);
        final next = entry.next;
        final readN = vols.where((v) => v.isRead).length;
        final authors = vols.map((v) => v.any.displayAuthor).whereType<String>().toSet();
        final time = vols.fold<int>(0, (a, v) => a + v.any.minutes);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 16, 4),
            child: _crumbs([('Library', Nav.I.closeDetail), (entry.label, null)]),
          ),
          if (isPhone) _phoneHead(context, first, authors, vols, readN, time, next, editions),
          if (!isPhone)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(lk.rPanel),
                child: SizedBox(width: 130, height: 195, child: BookCover(book: first, width: 130)),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SelectableText(entry.label, style: ts(size: 22, w: FontWeight.w700)),
                  if (authors.isNotEmpty) Text(authors.take(2).join(', '), style: ts(c: tk.sec, size: 14)),
                  const SizedBox(height: 8),
                  Text('${vols.length} volumes · $readN read${time > 0 ? ' · about ${(time / 60).round()} h of reading' : ''}',
                      style: ts(c: tk.faint)),
                  const SizedBox(height: 8),
                  SizedBox(width: 320, child: Progress(value: vols.isEmpty ? 0 : readN / vols.length, height: 5)),
                  const SizedBox(height: 14),
                  Row(children: [
                    Btn.primary(
                        next.inProgress
                            ? 'Continue ${next.any.volumeText} · ${(next.progress * 100).floor()}%'
                            : (readN == vols.length ? 'Read again from ${vols.first.any.volumeText}' : 'Read ${next.any.volumeText}'),
                        icon: Icons.auto_stories,
                        onTap: () => openBook(context, next.primary)),
                    const SizedBox(width: 8),
                    IconBtn(vols.every((v) => v.favourite) ? Icons.favorite : Icons.favorite_border,
                        tooltip: 'Favourite every volume', onTap: () => Library.I.toggleFavourite(vols)),
                    TagMenu(volumes: vols),
                    const SizedBox(width: 8),
                    if (editions.length > 1)
                      Seg<String>(
                        value: edition!,
                        items: [for (final e in editions) (e, e.isEmpty ? 'Light novel' : e)],
                        onChanged: (e) => setState(() {
                          edition = e;
                          ticked.clear();
                        }),
                      ),
                  ]),
                ]),
              ),
            ]),
          ),
          if (ticked.isNotEmpty)
            Padding(
              padding: isPhone ? const EdgeInsets.fromLTRB(12, 0, 12, 8) : const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
                Text('${ticked.length} ticked', style: ts(w: FontWeight.w600)),
                if (isPhone) ...[
                  const SizedBox(width: 10),
                  Btn('Download', dense: true, icon: Icons.download_outlined, onTap: () {
                    Downloads.I.add(vols.where((v) => ticked.contains(v.key)).map((v) => v.primary));
                    setState(ticked.clear);
                  }),
                ],
                const SizedBox(width: 10),
                Btn('Mark read', dense: true, icon: Icons.done_all, onTap: () => Library.I.markRead(vols.where((v) => ticked.contains(v.key)), true)),
                const SizedBox(width: 6),
                Btn('Mark unread', dense: true, icon: Icons.remove_done, onTap: () => Library.I.markRead(vols.where((v) => ticked.contains(v.key)), false)),
                const SizedBox(width: 6),
                TagMenu(volumes: vols.where((v) => ticked.contains(v.key)).toList()),
                const SizedBox(width: 12),
                Btn.ghost('Clear', dense: true, onTap: () => setState(ticked.clear)),
              ])),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              itemCount: vols.length,
              itemBuilder: (_, i) => _row(context, vols[i], vols),
            ),
          ),
        ]);
      },
    );
  }

  /// The phone's series header: cover and title side by side, buttons below.
  Widget _phoneHead(BuildContext context, Book first, Set<String> authors, List<Volume> vols, int readN, int time,
      Volume next, List<String> editions) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(lk.rPanel),
            child: SizedBox(width: 90, height: 135, child: BookCover(book: first, width: 90)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Library.I.seriesOf(first) == null ? first.cardTitle : (first.displaySeries ?? first.cardTitle),
                  style: ts(size: 18, w: FontWeight.w700)),
              if (authors.isNotEmpty) Text(authors.take(2).join(', '), style: ts(c: tk.sec)),
              const SizedBox(height: 6),
              Text('${vols.length} volumes · $readN read${time > 0 ? ' · about ${(time / 60).round()} h' : ''}',
                  style: ts(c: tk.faint, size: 12.5)),
              const SizedBox(height: 6),
              Progress(value: vols.isEmpty ? 0 : readN / vols.length, height: 4),
              const SizedBox(height: 6),
              Row(children: [
                IconBtn(vols.every((v) => v.favourite) ? Icons.favorite : Icons.favorite_border,
                    size: 20, tooltip: 'Favourite every volume', onTap: () => Library.I.toggleFavourite(vols)),
                TagMenu(volumes: vols),
              ]),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        Btn.primary(
            next.inProgress
                ? 'Continue ${next.any.volumeText} · ${(next.progress * 100).floor()}%'
                : (readN == vols.length ? 'Read again from ${vols.first.any.volumeText}' : 'Read ${next.any.volumeText}'),
            icon: Icons.auto_stories,
            onTap: () => openBook(context, next.primary)),
        const SizedBox(height: 8),
        SeriesDownloads(vols),
        if (editions.length > 1) ...[
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Seg<String>(
              value: edition!,
              items: [for (final e in editions) (e, e.isEmpty ? 'Light novel' : e)],
              onChanged: (e) => setState(() {
                edition = e;
                ticked.clear();
              }),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _row(BuildContext context, Volume v, List<Volume> vols) {
    final b = v.primary;
    final on = ticked.contains(v.key);
    final sub = b.subtitle ?? (b.metaTitle != null && normKey(b.metaTitle!) != normKey(b.displaySeries ?? '') ? b.displayTitle : '');
    return Hoverable(
      builder: (h) => GestureDetector(
        onTap: () {
          if (HardwareKeyboard.instance.isControlPressed || ticked.isNotEmpty) {
            setState(() => on ? ticked.remove(v.key) : ticked.add(v.key));
          } else {
            Nav.I.openVolume(v);
          }
        },
        onDoubleTap: isPhone ? null : () => openBook(context, b),
        onLongPress: isPhone ? () => setState(() => on ? ticked.remove(v.key) : ticked.add(v.key)) : null,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: on ? lk.tint(tk.ground, 0.17) : (h ? tk.raised : null),
            borderRadius: BorderRadius.circular(lk.rControl),
          ),
          child: Row(children: [
            if (!isPhone || ticked.isNotEmpty) ...[
              SizedBox(width: 28, child: Checkbox(value: on, onChanged: (_) => setState(() => on ? ticked.remove(v.key) : ticked.add(v.key)))),
              const SizedBox(width: 6),
            ],
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                width: 40,
                height: 60,
                child: Stack(children: [
                  Positioned.fill(child: BookCover(book: b, width: 40)),
                  Positioned(left: 0, right: 0, bottom: 0, child: ProgressLine(value: v.progress)),
                ]),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(b.volumeText.isEmpty ? b.displayTitle : b.volumeText, style: ts(w: FontWeight.w600)),
                if (sub.isNotEmpty) Text(sub, style: ts(c: tk.sec, size: 12), overflow: TextOverflow.ellipsis),
              ]),
            ),
            if (v.isRead) Icon(Icons.check_circle, size: 16, color: tk.ok) else if (v.inProgress) Text('${(v.progress * 100).floor()}%', style: ts(c: lk.acc, w: FontWeight.w600, tab: true)),
            if (isPhone) ...[
              if (Downloads.I.isDone(b)) ...[const SizedBox(width: 8), Icon(Icons.download_done, size: 16, color: tk.sec)],
              if (Downloads.I.isQueued(b)) ...[const SizedBox(width: 8), Icon(Icons.downloading, size: 16, color: lk.acc)],
            ] else ...[
            const SizedBox(width: 16),
            SizedBox(width: 84, child: v.rating > 0 ? Stars(value: v.rating, size: 13) : const SizedBox()),
            SizedBox(width: 70, child: Text(v.formats.map((f) => f.format.toUpperCase()).join(' '), style: ts(c: tk.faint, size: 11.5))),
            SizedBox(width: 110, child: Text(lengthText(b).split(' · ').first, style: ts(c: tk.faint, size: 12))),
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
                PopupMenuItem(value: 'read', child: Text('Read', style: ts())),
                PopupMenuItem(value: 'mark', child: Text(v.isRead ? 'Mark unread' : 'Mark read', style: ts())),
                PopupMenuItem(value: 'prev', child: Text('Mark this and earlier volumes read', style: ts())),
                if (!isPhone) PopupMenuItem(value: 'folder', child: Text('Show in folder', style: ts())),
                if (isPhone && !Downloads.I.isDone(b) && !Downloads.I.isQueued(b))
                  PopupMenuItem(value: 'download', child: Text('Download (${humanSize(b.size)})', style: ts())),
                if (isPhone && Downloads.I.isDone(b)) PopupMenuItem(value: 'remove', child: Text('Remove from this phone', style: ts())),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

