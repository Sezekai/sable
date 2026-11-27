import 'package:material_ui/material_ui.dart';

import '../core/db.dart';
import '../core/jobs.dart';
import '../core/library.dart';
import '../core/platform.dart';
import 'app.dart';
import 'library_page.dart';
import 'reader_page.dart';
import 'widgets.dart';

class _Item {
  _Item(this.at, this.title, {this.session, this.note});
  final int at;
  final Book title;
  final ReadingSession? session;
  final String? note;
}

/// Every reading session, newest first, grouped by day.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Library.I,
      builder: (context, _) {
        final items = <_Item>[];
        for (final s in Db.I.sessions()) {
          final t = Library.I.byId(s.bookId);
          if (t != null) items.add(_Item(s.startedAt, t, session: s));
        }
        for (final c in Db.I.completions()) {
          if (!c.$3) continue;
          final t = Library.I.byId(c.$1);
          if (t != null) items.add(_Item(c.$2, t, note: 'Marked read by hand'));
        }
        final query = q.toLowerCase();
        final list =
            items
                .where(
                  (i) =>
                      query.isEmpty ||
                      '${i.title.displayTitle} ${i.title.displaySeries ?? ''} ${i.title.displayAuthor ?? ''}'.toLowerCase().contains(query),
                )
                .toList()
              ..sort((a, b) => b.at.compareTo(a.at));
        final rows = <Widget>[];
        String? lastDay;
        for (final it in list) {
          final day = _dayLabel(it.at);
          if (day != lastDay) {
            rows.add(
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
                child: Text(
                  day,
                  style: ts(w: FontWeight.w700, c: tk.sec),
                ),
              ),
            );
            lastDay = day;
          }
          // A faint line between entries of the same day.
          if (rows.isNotEmpty && rows.last is! Padding) {
            rows.add(Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 8), color: tk.line.withValues(alpha: 0.55)));
          }
          rows.add(_row(it));
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('History', style: ts(size: 15, w: FontWeight.w700)),
                  const SizedBox(width: 10),
                  if (!isPhone)
                    Expanded(
                      child: Text('Every time you read: when, for how long, and how far you got.', style: ts(c: tk.sec)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              PanelBox(
                child: Row(
                  children: [
                    Expanded(
                      child: Field(hint: 'Search history', icon: Icons.search, onChanged: (v) => setState(() => q = v)),
                    ),
                    // On the phone the history belongs to the PC, so it's cleared there.
                    if (!isPhone) const SizedBox(width: 8),
                    if (!isPhone)
                      Btn(
                        'Clear history',
                        kind: BtnKind.dangerGhost,
                        onTap: () async {
                          final ok = await confirm(
                            context,
                            'Clear all reading history?',
                            'Reading sessions are removed. Read counts, ratings, favourites and tags stay, and your files aren\'t touched.',
                            confirmLabel: 'Clear history',
                            danger: true,
                          );
                          if (ok) {
                            Db.I.raw.execute('DELETE FROM sessions');
                            Library.I.changed();
                          }
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: rows.isEmpty
                    ? const EmptyState(icon: Icons.history, text: 'Nothing read yet. What you read shows up here.')
                    : Smooth(
                        builder: (sc) => ListView(controller: sc, children: rows),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _dayLabel(int at) {
    if (at <= 0) return 'Date unknown';
    final d = DateTime.fromMillisecondsSinceEpoch(at * 1000);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const w = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    if (diff < 7) return w[d.weekday - 1];
    return dateText(at);
  }

  /// The phone: two short lines instead of columns.
  Widget _phoneRow(_Item it) {
    final t = it.title;
    final s = it.session;
    final what = s == null
        ? (it.note ?? '')
        : '${timeText(s.startedAt)} · ${humanHours(s.activeSeconds)} · ${(s.fromPct * 100).floor()}% → ${(s.toPct * 100).floor()}%'
              '${s.completed ? ' · finished' : ''} · ${s.device}';
    return GestureDetector(
      onTap: () => _openPage(t),
      onLongPress: s == null
          ? null
          : () async {
              if (await confirm(
                context,
                'Remove this history entry?',
                'Only the record of this session is removed.',
                confirmLabel: 'Remove entry',
              )) {
                Db.I.deleteSession(s.id);
                Library.I.changed();
              }
            },
      child: Container(
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 58,
              height: 87,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: BookCover(book: t, width: 58),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.inSeries ? '${t.cardTitle}${t.volumeText.isEmpty ? '' : ' · ${t.volumeText}'}' : t.displayTitle,
                    style: ts(w: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    what,
                    style: ts(c: tk.sec, size: 12.5, tab: true),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ],
              ),
            ),
            IconBtn(Icons.play_arrow_rounded, size: 22, tooltip: 'Read', onTap: () => openBook(context, t)),
          ],
        ),
      ),
    );
  }

  /// A click on an entry opens the book's page (books read from outside the
  /// library have no page: they open in the reader).
  void _openPage(Book t) {
    final v = Library.I.volumeOf(t);
    if (v == null || t.outside) {
      openBook(context, t);
    } else {
      Nav.I.openVolume(v);
    }
  }

  Widget _row(_Item it) {
    if (isPhone) return _phoneRow(it);
    final t = it.title;
    final s = it.session;
    return Hoverable(
      builder: (h) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openPage(t),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            height: 68,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: h ? tk.raised : null, borderRadius: BorderRadius.circular(lk.rControl)),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  height: 60,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: BookCover(book: t, width: 42),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              t.inSeries ? '${t.cardTitle}${t.volumeText.isEmpty ? '' : ' · ${t.volumeText}'}' : t.displayTitle,
                              style: ts(w: FontWeight.w600),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Btn.ghost(
                            t.isRead && t.progress >= 0.999 ? 'Read again' : 'Continue',
                            icon: Icons.play_arrow_rounded,
                            dense: true,
                            onTap: () => openBook(context, t),
                          ),
                        ],
                      ),
                      Text(
                        [if (t.displayAuthor != null) t.displayAuthor!, t.format.toUpperCase()].join(' · '),
                        style: ts(c: tk.faint, size: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (s != null) ...[
                  SizedBox(
                    width: 130,
                    child: Text('${timeText(s.startedAt)} → ${timeText(s.endedAt)}', style: ts(c: tk.sec, tab: true)),
                  ),
                  SizedBox(
                    width: 80,
                    child: Text(humanHours(s.activeSeconds), style: ts(c: tk.sec, tab: true)),
                  ),
                  SizedBox(
                    width: 170,
                    child: Text(
                      '${(s.fromPct * 100).floor()}% → ${(s.toPct * 100).floor()}% · ${s.pagesRead} pages',
                      style: ts(c: tk.sec, tab: true),
                    ),
                  ),
                  SizedBox(
                    width: 70,
                    child: s.completed
                        ? Text(
                            'Finished',
                            style: ts(c: tk.ok, w: FontWeight.w600),
                          )
                        : const SizedBox(),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(s.device, style: ts(c: tk.faint, size: 12)),
                  ),
                ] else
                  SizedBox(
                    width: 490,
                    child: Text(it.note ?? '', style: ts(c: tk.sec)),
                  ),
                if (s != null)
                  IconBtn(
                    Icons.delete_outline,
                    tooltip: 'Remove this entry',
                    onTap: () async {
                      if (await confirm(
                        context,
                        'Remove this history entry?',
                        'Only the record of this session is removed.',
                        confirmLabel: 'Remove entry',
                      )) {
                        Db.I.deleteSession(s.id);
                        Library.I.changed();
                      }
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
