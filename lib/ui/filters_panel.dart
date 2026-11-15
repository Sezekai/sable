import 'package:material_ui/material_ui.dart';

import '../core/library.dart';
import 'widgets.dart';

/// Library filters. Clicking a filter cycles: off → on → its opposite.
class FiltersPanel extends StatefulWidget {
  const FiltersPanel({super.key});
  @override
  State<FiltersPanel> createState() => _FiltersPanelState();
}

class _FiltersPanelState extends State<FiltersPanel> {
  String artistSearch = '';
  LibFilter get f => Library.I.filter;

  void _set(VoidCallback fn) {
    setState(fn);
    Library.I.changed();
  }

  Widget _tri(String label, String opposite, Tri v, ValueChanged<Tri> on) => Pill(
        v == Tri.no ? opposite : label,
        active: v != Tri.any,
        negative: false,
        color: v == Tri.no ? tk.danger : null,
        onTap: () => _set(() => on(nextTri(v))),
      );

  @override
  Widget build(BuildContext context) {
    final artistCounts = Library.I.authorCounts();
    final artists = artistCounts.keys
        .where((a) => artistSearch.isEmpty || a.toLowerCase().contains(artistSearch.toLowerCase()))
        .toList()
      ..sort((a, b) => artistCounts[b]!.compareTo(artistCounts[a]!));
    final tags = Library.I.tags;
    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 90, right: 20),
        child: Material(
          color: tk.panel,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(lk.rPanel), side: BorderSide(color: tk.line2)),
          elevation: 12,
          child: SizedBox(
            width: 520,
            height: 600,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text('Filters', style: ts(size: lk.fontSize + 2, w: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Click once for the filter, again for its opposite, again to clear.', style: ts(c: tk.faint, size: 12))),
                  IconBtn(Icons.close, onTap: () => Navigator.pop(context)),
                ]),
                const SizedBox(height: 10),
                Expanded(
                  child: ListView(children: [
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      _tri('Read', 'Unread', f.read, (v) => f.read = v),
                      _tri('In progress', 'Not started or finished', f.inProgress, (v) => f.inProgress = v),
                      _tri('Favourite', 'Not favourite', f.favourite, (v) => f.favourite = v),
                      _tri('Rated', 'Not rated', f.rated, (v) => f.rated = v),
                      _tri('In a series', 'Single book', f.series, (v) => f.series = v),
                      _tri('Light novels', 'Books', f.ln, (v) => f.ln = v),
                      _tri('PDF only', 'Not PDF', f.pdf, (v) => f.pdf = v),
                    ]),
                    const SizedBox(height: 14),
                    _range('Rating', f.ratingRange, (v) => f.ratingRange = v,
                        RangeValues(f.minRating, f.maxRating), 0.5, 5, 9, (r) {
                      f.minRating = r.start;
                      f.maxRating = r.end;
                    }, (r) => '${r.start} to ${r.end} stars'),
                    _range('Length', f.lengthRange, (v) => f.lengthRange = v,
                        RangeValues(f.minLength.toDouble(), f.maxLength.toDouble()), 0, 1500, 150, (r) {
                      f.minLength = r.start.round();
                      f.maxLength = r.end.round();
                    }, (r) => '${r.start.round()} to ${r.end.round()} pages'),
                    _single('Times read', f.readCount, (v) => f.readCount = v, f.readCountMin.toDouble(), 1, 20,
                        (v) => f.readCountMin = v.round(), (v) => 'Read ${v.round()}+ times', 'Read fewer times'),
                    _single('Read recently', f.readIn, (v) => f.readIn = v, f.readInDays.toDouble(), 1, 365,
                        (v) => f.readInDays = v.round(), (v) => 'Read in the last ${v.round()} days', 'Not read in that time'),
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text('Tags', style: ts(w: FontWeight.w600, c: tk.sec)),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        for (final t in tags)
                          Pill(
                            f.excludeTags.contains(t.id) ? 'not ${t.name}' : t.name,
                            active: f.tags.contains(t.id) || f.excludeTags.contains(t.id),
                            color: f.excludeTags.contains(t.id) ? tk.danger : Color(t.color),
                            onTap: () => _set(() {
                              if (f.tags.contains(t.id)) {
                                f.tags.remove(t.id);
                                f.excludeTags.add(t.id);
                              } else if (f.excludeTags.contains(t.id)) {
                                f.excludeTags.remove(t.id);
                              } else {
                                f.tags.add(t.id);
                              }
                            }),
                          ),
                      ]),
                    ],
                    const SizedBox(height: 14),
                    Row(children: [
                      Text('Authors', style: ts(w: FontWeight.w600, c: tk.sec)),
                      const SizedBox(width: 10),
                      Expanded(child: Field(hint: 'Find an author', icon: Icons.search, onChanged: (v) => setState(() => artistSearch = v))),
                    ]),
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final a in artists.take(80))
                        Pill(
                          '${f.excludeAuthors.contains(a) ? 'not ' : ''}$a  ${artistCounts[a]}',
                          active: f.authors.contains(a) || f.excludeAuthors.contains(a),
                          color: f.excludeAuthors.contains(a) ? tk.danger : null,
                          onTap: () => _set(() {
                            if (f.authors.contains(a)) {
                              f.authors.remove(a);
                              f.excludeAuthors.add(a);
                            } else if (f.excludeAuthors.contains(a)) {
                              f.excludeAuthors.remove(a);
                            } else {
                              f.authors.add(a);
                            }
                          }),
                        ),
                      if (artists.length > 80) Text('${artists.length - 80} more; type to find them', style: ts(c: tk.faint, size: 12)),
                    ]),
                  ]),
                ),
                Row(children: [
                  Btn.ghost('Clear all', onTap: () => _set(() {
                    final keep = f.search;
                    Library.I.filter = LibFilter()..search = keep;
                  })),
                  const Spacer(),
                  Btn.primary('Done', onTap: () => Navigator.pop(context)),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _range(String label, Tri v, ValueChanged<Tri> setTri, RangeValues values, double min, double max, int divisions,
      ValueChanged<RangeValues> onRange, String Function(RangeValues) text) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        SizedBox(width: 88, child: Text(label, style: ts(c: tk.sec))),
        Pill(v == Tri.no ? 'Outside' : 'Within', active: v != Tri.any, color: v == Tri.no ? tk.danger : null,
            onTap: () => _set(() => setTri(nextTri(v)))),
        Expanded(
          child: RangeSlider(
            values: RangeValues(values.start.clamp(min, max), values.end.clamp(min, max)),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: (r) => _set(() {
              onRange(r);
              if (v == Tri.any) setTri(Tri.yes);
            }),
          ),
        ),
        SizedBox(width: 130, child: Text(text(values), style: ts(c: tk.sec, size: 12, tab: true))),
      ]),
    );
  }

  Widget _single(String label, Tri v, ValueChanged<Tri> setTri, double value, double min, double max,
      ValueChanged<double> on, String Function(double) text, String opposite) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        SizedBox(width: 88, child: Text(label, style: ts(c: tk.sec))),
        Pill(v == Tri.no ? opposite : 'On', active: v != Tri.any, color: v == Tri.no ? tk.danger : null,
            onTap: () => _set(() => setTri(nextTri(v)))),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: (x) => _set(() {
              on(x);
              if (v == Tri.any) setTri(Tri.yes);
            }),
          ),
        ),
        SizedBox(width: 130, child: Text(text(value), style: ts(c: tk.sec, size: 12, tab: true))),
      ]),
    );
  }
}
