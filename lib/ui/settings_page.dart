import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../core/db.dart';
import '../core/jobs.dart';
import '../core/library.dart';
import '../core/log.dart';
import '../core/paths.dart';
import '../core/downloads.dart';
import '../core/extras.dart';
import '../core/file_assoc.dart';
import '../core/platform.dart';
import '../core/settings.dart';
import '../core/sync_server.dart';
import 'look.dart';
import 'phone.dart';
import 'reader_page.dart';
import 'widgets.dart';

/// The section open on the phone (Android's back closes it first).
final settingsSection = ValueNotifier<String?>(null);

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final Map<String, int?> sizes = {};

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final places = _places();
    for (final pl in places) {
      sizes[pl.$2] = null;
    }
    if (mounted) setState(() {});
    for (final pl in places) {
      final n = await _dirSize(pl.$2);
      if (!mounted) return;
      setState(() => sizes[pl.$2] = n);
    }
  }

  static Future<int> _dirSize(String path) async {
    final d = Directory(path);
    if (!await d.exists()) return 0;
    var total = 0;
    try {
      await for (final f in d.list(recursive: true, followLinks: false)) {
        if (f is File) total += await f.length();
      }
    } catch (_) {}
    return total;
  }

  List<(String, String, bool canMove, bool canClear)> _places() => [
    ('Settings, library database and appearance', AppPaths.I.data, true, false),
    ('Log files', AppPaths.I.logs, false, false),
    ('Database backups', AppPaths.I.backups, false, false),
    ('Cover cache', AppPaths.I.thumbs, true, true),
    ('Books copied out of ZIPs while reading (cache)', AppPaths.I.bookCache, true, true),
    ('Book engine (WebView2) data', p.join(AppPaths.I.data, 'WebView2'), false, false),
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Settings.I, Look.I, Library.I, settingsSection]),
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (isPhone && section != null) ...[
                  IconBtn(Icons.arrow_back, size: 22, box: 40, tooltip: 'Back', onTap: () => setState(() => section = null)),
                  const SizedBox(width: 4),
                ],
                Text(isPhone && section != null ? section! : 'Settings', style: ts(size: 15, w: FontWeight.w700)),
                const SizedBox(width: 10),
                if (!isPhone) Text('Changes apply straight away.', style: ts(c: tk.sec)),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _sections([
                if (isPhone)
                  _group('Connection', 'Your PC is where the books are. The phone keeps the library, history and the books you download.', [
                    const PhoneConnection(),
                  ]),
                if (!isPhone)
                  _group(
                    'Phone',
                    'Read on your Android phone too: it keeps the whole library and syncs reading, history, favourites, ratings, tags and bookmarks with this PC over your home WiFi.',
                    [const _PcPhone()],
                  ),
                if (!isPhone)
                  _group(
                    'Library folders',
                    'Where your books are. Light novel folders treat each folder inside as a series. Collections can be hidden from the library in one click.',
                    [..._folders()],
                  ),
                _group('Look', 'Each theme can be changed and keeps your changes. The book page follows the theme too.', [..._look()]),
                _group('Reader', 'The default for every book. A change made while reading is kept for that book only; use "Save as default for all books" in the reader to make it the default.', [
                  _row(
                    'Font',
                    Drop<String>(
                      value: Settings.I.style.font,
                      width: 220,
                      items: [for (final f in readingFonts) (f, fontLabel(f))],
                      onChanged: (v) {
                        Settings.I.style.font = v;
                        Settings.I.save();
                      },
                    ),
                    changed: Settings.I.style.font != _d.style.font,
                    reset: () {
                      Settings.I.style.font = _d.style.font;
                      Settings.I.save();
                    },
                  ),
                  _row(
                    'Pages at once',
                    Seg<PageLayout>(
                      value: Settings.I.style.layout,
                      items: const [
                        (PageLayout.auto, 'Auto (two when the window is wide)'),
                        (PageLayout.one, 'One'),
                        (PageLayout.two, 'Two'),
                      ],
                      onChanged: (v) {
                        Settings.I.style.layout = v;
                        Settings.I.save();
                      },
                    ),
                    changed: Settings.I.style.layout != _d.style.layout,
                    reset: () {
                      Settings.I.style.layout = _d.style.layout;
                      Settings.I.save();
                    },
                  ),
                  _row(
                    'Turning',
                    Seg<PageFlow>(
                      value: Settings.I.style.flow,
                      items: const [(PageFlow.paged, 'Pages'), (PageFlow.scrolled, 'Scroll')],
                      onChanged: (v) {
                        Settings.I.style.flow = v;
                        Settings.I.save();
                      },
                    ),
                    changed: Settings.I.style.flow != _d.style.flow,
                    reset: () {
                      Settings.I.style.flow = _d.style.flow;
                      Settings.I.save();
                    },
                  ),
                  if (!isPhone)
                    _row(
                      'Mouse back / forward',
                      Seg<String>(
                        value: Settings.I.mouseInReader,
                        items: const [('pages', 'Turn pages'), ('leave', 'Back leaves the book')],
                        onChanged: (v) {
                          Settings.I.mouseInReader = v;
                          Settings.I.save();
                        },
                      ),
                      changed: Settings.I.mouseInReader != _d.mouseInReader,
                      reset: () {
                        Settings.I.mouseInReader = _d.mouseInReader;
                        Settings.I.save();
                      },
                    ),
                  _check(
                    'Skip volumes already read when moving to the next volume',
                    Settings.I.skipRead,
                    (v) => Settings.I.skipRead = v,
                    def: _d.skipRead,
                  ),
                  _check(
                    'Show PDFs with dark pages (inverts their colours)',
                    Settings.I.pdfDarkPages,
                    (v) => Settings.I.pdfDarkPages = v,
                    def: _d.pdfDarkPages,
                  ),
                  _row(
                    'Idle after',
                    Row(
                      children: [
                        Drop<int>(
                          value: Settings.I.idleMinutes,
                          items: const [
                            (1, '1 minute'),
                            (2, '2 minutes'),
                            (3, '3 minutes'),
                            (5, '5 minutes'),
                            (10, '10 minutes'),
                            (30, '30 minutes'),
                          ],
                          onChanged: (v) {
                            Settings.I.idleMinutes = v;
                            Settings.I.save();
                          },
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text('Time with no page turns isn\'t counted as reading.', style: ts(c: tk.faint, size: 12)),
                        ),
                      ],
                    ),
                    changed: Settings.I.idleMinutes != _d.idleMinutes,
                    reset: () {
                      Settings.I.idleMinutes = _d.idleMinutes;
                      Settings.I.save();
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    Platform.isWindows
                        ? (ReaderWeb.runtimeVersion == null
                              ? (ReaderWeb.checked
                                    ? 'The WebView2 Runtime isn\'t installed, so EPUB and MOBI books can\'t be opened.'
                                    : 'The book engine starts when you open a book.')
                              : 'Book engine: Microsoft Edge WebView2 ${ReaderWeb.runtimeVersion}')
                        : '',
                    style: ts(c: ReaderWeb.checked && ReaderWeb.runtimeVersion == null ? tk.warn : tk.faint, size: 12),
                  ),
                  const SizedBox(height: 6),
                  Btn.ghost(
                    'Reset all reader settings',
                    icon: Icons.restart_alt,
                    onTap: () {
                      Settings.I.style.apply(ReadingStyle().toJson());
                      Settings.I.skipRead = _d.skipRead;
                      Settings.I.pdfDarkPages = _d.pdfDarkPages;
                      Settings.I.mouseInReader = _d.mouseInReader;
                      Settings.I.idleMinutes = _d.idleMinutes;
                      Settings.I.save();
                      toast('Reader settings are back to their defaults');
                    },
                  ),
                ]),
                _group('Library', 'How the library behaves.', [
                  _check(
                    'Show a reading progress line on covers',
                    Settings.I.progressLine,
                    (v) => Settings.I.progressLine = v,
                    def: _d.progressLine,
                  ),
                  _check(
                    'Show "Continue reading" at the top of the library',
                    Settings.I.showContinue,
                    (v) => Settings.I.showContinue = v,
                    def: _d.showContinue,
                  ),
                  _check('Show books from collections', Settings.I.showCollections, (v) {
                    Settings.I.showCollections = v;
                    Library.I.changed();
                  }, def: _d.showCollections),
                  if (!isPhone) ...[
                    _check('Watch the folders and add new books by themselves', Settings.I.watchFolders, (v) {
                      Settings.I.watchFolders = v;
                      Library.I.startWatching();
                    }, def: _d.watchFolders),
                    const SizedBox(height: 8),
                    Text('ZIP passwords', style: ts(w: FontWeight.w600)),
                    Text(
                      'Locked ZIPs are opened with these, and with any password in a .txt file with "password" in its name in a library folder '
                      '(like "Password for many rars.txt"). The ZIPs themselves aren\'t changed.',
                      style: ts(c: tk.sec, size: 12),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final pw in Settings.I.zipPasswords)
                          TagChip(
                            '•' * pw.length.clamp(4, 12),
                            tk.sec,
                            onRemove: () {
                              Settings.I.zipPasswords.remove(pw);
                              Settings.I.save();
                            },
                          ),
                        Btn(
                          'Add a password…',
                          icon: Icons.key_outlined,
                          dense: true,
                          onTap: () async {
                            final pw = await ask(
                              context,
                              'Add a ZIP password',
                              body: 'Sable tries it on locked ZIPs at the next scan, which starts now.',
                              confirmLabel: 'Add',
                            );
                            if (pw == null || pw.isEmpty) return;
                            Settings.I.zipPasswords.add(pw);
                            Settings.I.save();
                            Library.I.scan();
                          },
                        ),
                        Text('${Library.I.zipPasswords.length} passwords in use', style: ts(c: tk.faint, size: 12)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        Btn('Scan the library', icon: Icons.refresh, onTap: Library.I.scan),
                        Btn(
                          'Read file names again',
                          icon: Icons.text_fields,
                          tooltip: 'Applies the series and volume rules again. Your edits are kept.',
                          onTap: () {
                            Library.I.reapplyFolders();
                            toast('File names read again');
                          },
                        ),
                        Btn('Make missing covers', icon: Icons.image_outlined, onTap: Covers.I.queueMissing),
                      ],
                    ),
                  ],
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      Btn.ghost(
                        'Reset these library settings',
                        icon: Icons.restart_alt,
                        onTap: () {
                          Settings.I
                            ..progressLine = _d.progressLine
                            ..showContinue = _d.showContinue
                            ..showCollections = _d.showCollections
                            ..watchFolders = _d.watchFolders
                            ..save();
                          Library.I.startWatching();
                          Library.I.changed();
                        },
                      ),
                    ],
                  ),
                ]),
                _group(
                  'Descriptions and covers',
                  'Books and series without a description can have one looked up online (Apple Books, Google Books, then Open Library). Your own descriptions and covers are never replaced. Edit or change them on each book or series page.',
                  [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Btn(
                          'Find missing descriptions',
                          icon: Icons.travel_explore,
                          onTap: () {
                            final all = Library.I.entries();
                            Lookup.run(
                              volumes: Library.I.volumes.values.where((v) => !v.any.missing).toList(),
                              series: all.whereType<SeriesEntry>().toList(),
                            );
                            toast('Looking up descriptions: see the progress in the jobs bar');
                          },
                        ),
                        Text(
                          '${Library.I.volumes.values.where((v) => !v.any.missing && v.primary.shownDescription == null).length} books without one',
                          style: ts(c: tk.faint, size: 12),
                        ),
                      ],
                    ),
                  ],
                ),
                if (!isPhone && Platform.isWindows)
                  _group(
                    'Opening ebooks',
                    'Make Sable the app that opens EPUB, MOBI and AZW3 files when you double-click them. Books outside the library are tracked (history, position) without being added; if you add them later, their progress is already there.',
                    [const _DefaultApp()],
                  ),
                if (!isPhone)
                  _group('Storage', 'Everywhere Sable keeps things, and how much space each uses.', [
                    for (final pl in _places()) _storageRow(pl),
                  ]),
                if (isPhone)
                  _group('Storage', 'What Sable keeps on this phone.', [
                    ListenableBuilder(
                      listenable: Downloads.I,
                      builder: (_, _) =>
                          Text('Downloaded books: ${Downloads.I.done.length} · ${humanSize(Downloads.I.usedBytes)}', style: ts()),
                    ),
                    FutureBuilder<int>(
                      future: _dirSize(AppPaths.I.thumbs),
                      builder: (_, snap) => Text(
                        'Covers: ${snap.hasData ? humanSize(snap.data!) : '…'} (kept for the whole library, so it can be browsed away from the PC)',
                        style: ts(c: tk.sec, size: 12.5),
                      ),
                    ),
                    Text('Data: ${AppPaths.I.data}', style: ts(c: tk.faint, size: 12)),
                    Text('Books and covers: ${AppPaths.I.cache}', style: ts(c: tk.faint, size: 12)),
                  ]),
                _group('Reset', 'Each part asks first and says exactly what is cleared. Your files are never deleted.', [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _reset('Settings', 'All settings go back to their defaults. Your library, history and themes stay.', () {
                        Settings.I.resetToDefaults();
                      }),
                      if (!isPhone)
                        _reset(
                          'Library',
                          'Sable forgets every book, with its ratings, favourites, tags, bookmarks and history. Your files stay on disk.',
                          () {
                            Db.I.resetLibrary();
                            Library.I.load();
                          },
                        ),
                      if (!isPhone)
                        _reset('History', 'All reading sessions, read counts and reading positions are cleared. Books, ratings, favourites, tags and bookmarks stay.', () {
                          Db.I.resetHistory();
                          Library.I.load();
                        }),
                      _reset(
                        'Look',
                        'Both themes lose your colour changes, the accents and sizes go back to their defaults, and OLED black is chosen.',
                        () {
                          Look.I.resetToDefault();
                        },
                      ),
                      _reset('Cover cache', 'Covers are made again when needed.', () async {
                        await _clear(AppPaths.I.thumbs);
                      }),
                      if (!isPhone)
                        _reset('Book cache', 'Books copied out of ZIPs are removed; they\'re copied again when opened.', () async {
                          await _clear(AppPaths.I.bookCache);
                        }),
                    ],
                  ),
                ]),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  String? get section => settingsSection.value;
  set section(String? v) => settingsSection.value = v;
  String? pcSection;

  static IconData _iconFor(String t) => switch (t) {
    'Connection' || 'Phone' => Icons.phone_android,
    'Library folders' => Icons.folder_outlined,
    'Look' => Icons.palette_outlined,
    'Reader' => Icons.menu_book_outlined,
    'Library' => Icons.grid_view,
    'Descriptions and covers' => Icons.travel_explore,
    'Opening ebooks' => Icons.open_in_new,
    'Storage' => Icons.storage_outlined,
    'Reset' => Icons.restart_alt,
    _ => Icons.settings_outlined,
  };

  /// Sections: a column of them on the left on PC; on the phone a list to tap into.
  Widget _sections(List<Widget> groups) {
    final boxes = groups.whereType<_GroupBox>().toList();
    if (isPhone) {
      final open = boxes.where((b) => b.title == section).firstOrNull;
      if (open != null) {
        return Smooth(
          builder: (sc) => ListView(controller: sc, children: [open]),
        );
      }
      return Smooth(
        builder: (sc) => ListView(
          controller: sc,
          children: [
            for (final b in boxes)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => section = b.title),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                  child: Row(
                    children: [
                      GradIcon(_iconFor(b.title), size: 24),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(b.title, style: ts(size: 15, w: FontWeight.w600)),
                            Text(
                              b.desc,
                              style: ts(c: tk.faint, size: 12),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, color: tk.faint),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    }
    final cur = boxes.where((b) => b.title == pcSection).firstOrNull ?? boxes.first;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 220,
          child: Smooth(
            builder: (sc) => ListView(
              controller: sc,
              children: [
                for (final b in boxes)
                  Hoverable(
                    builder: (h) => GestureDetector(
                      onTap: () => setState(() => pcSection = b.title),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 2),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                          decoration: BoxDecoration(
                            gradient: b == cur ? softGrad(0.28) : null,
                            color: b != cur && h ? tk.raised : null,
                            borderRadius: BorderRadius.circular(lk.rControl),
                          ),
                          child: Row(
                            children: [
                              b == cur ? GradIcon(_iconFor(b.title), size: 18) : Icon(_iconFor(b.title), size: 18, color: tk.sec),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  b.title,
                                  style: ts(w: b == cur ? FontWeight.w700 : FontWeight.w500, c: b == cur ? tk.text : tk.sec),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Smooth(
            builder: (sc) => ListView(
              controller: sc,
              key: ValueKey(cur.title),
              children: [ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900), child: cur)],
            ),
          ),
        ),
      ],
    );
  }

  Widget _group(String title, String desc, List<Widget> children) => _GroupBox(
    weight: children.length + 3,
    title: title,
    desc: desc,
    child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tk.panel,
        borderRadius: BorderRadius.circular(lk.rPanel),
        border: Border.all(color: tk.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: ts(w: FontWeight.w700)),
          Text(desc, style: ts(c: tk.sec, size: 12)),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    ),
  );

  Settings get _d => Settings.defaults;

  /// The little "back to the default" button shown next to a changed setting.
  Widget _resetBtn(bool changed, VoidCallback? reset) => SizedBox(
    width: lk.hControl,
    child: changed && reset != null
        ? IconBtn(
            Icons.restart_alt,
            tooltip: 'Back to the default',
            onTap: () {
              reset();
              setState(() {});
            },
          )
        : null,
  );

  Widget _row(String label, Widget child, {bool changed = false, VoidCallback? reset}) => isPhone
      // A phone: the name above the setting, which gets the whole width.
      ? Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: ts(c: tk.sec, size: 12.5)),
              Row(
                children: [
                  Flexible(
                    child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: child),
                  ),
                  const SizedBox(width: 4),
                  _resetBtn(changed, reset),
                ],
              ),
            ],
          ),
        )
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              SizedBox(
                width: 180,
                child: Text(label, style: ts(c: tk.sec)),
              ),
              Flexible(
                child: Align(alignment: Alignment.centerLeft, child: child),
              ),
              const SizedBox(width: 6),
              _resetBtn(changed, reset),
            ],
          ),
        );

  Widget _check(String label, bool v, ValueChanged<bool> on, {bool? def}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      children: [
        Checkbox(
          value: v,
          onChanged: (x) {
            on(x ?? false);
            Settings.I.save();
          },
        ),
        const SizedBox(width: 4),
        Flexible(child: Text(label, style: ts())),
        const SizedBox(width: 6),
        _resetBtn(
          def != null && v != def,
          def == null
              ? null
              : () {
                  on(def);
                  Settings.I.save();
                },
        ),
      ],
    ),
  );

  /// A size: a slider in steps of 5%, plus a box to type any exact percentage.
  Widget _scale(double v, double min, double max, String note, void Function(double) set) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 10,
    runSpacing: 4,
    children: [
      SizedBox(
        width: 240,
        child: Slider(
          value: v.clamp(min, max),
          min: min,
          max: max,
          divisions: ((max - min) * 20).round(),
          onChanged: (x) => setState(() => set(x)),
          onChangeEnd: (_) => Look.I.save(),
        ),
      ),
      PercentField(
        value: v,
        min: min,
        max: max,
        onSet: (x) {
          setState(() => set(x));
          Look.I.save();
        },
      ),
      Text(note, style: ts(c: tk.faint, size: 12)),
    ],
  );

  // ---------------- look ----------------

  List<Widget> _look() {
    final lkI = Look.I;
    final themeName = lkI.theme;
    final tokens = lkI.t.toMap();
    final base = lkI.baseTokens(themeName).toMap();
    final ov = lkI.overrides[themeName] ?? const {};
    Widget swatch(Color c, {double w = 40, VoidCallback? onTap, Gradient? g}) => GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: Container(
          width: w,
          height: 22,
          decoration: BoxDecoration(
            color: g == null ? c : null,
            gradient: g,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: tk.line2),
          ),
        ),
      ),
    );
    return [
      _row(
        'Theme',
        Seg<String>(
          value: themeName,
          items: [for (final n in themes.keys) (n, lkI.themeEdited(n) ? '$n (edited)' : n)],
          onChanged: (v) => setState(() => lkI.setTheme(v)),
        ),
        changed: themeName != 'OLED black',
        reset: () => lkI.setTheme('OLED black'),
      ),
      if (themeName == 'Starlight')
        _row(
          'Stars',
          NumStep(
            value: (lkI.stars * 100).roundToDouble(),
            step: 10,
            min: 0,
            max: 400,
            title: 'Stars (% of the usual amount)',
            format: (v) => '${v.round()}%',
            onChanged: (v) => setState(() {
              lkI.stars = v / 100;
              lkI.save();
            }),
          ),
          changed: lkI.stars != 1.0,
          reset: () => setState(() {
            lkI.stars = 1.0;
            lkI.save();
          }),
        ),
      _row(
        'Accent',
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final e in accentPresets.entries)
              Tooltip(
                message: e.key,
                child: GestureDetector(
                  onTap: () => setState(() => lkI.setAccent(e.key)),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      width: 44,
                      height: 22,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: e.value.length == 1 ? [e.value.first, e.value.first] : e.value),
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(color: lkI.accentName == e.key ? tk.text : Colors.transparent, width: 2),
                      ),
                    ),
                  ),
                ),
              ),
            Pill('Custom', active: lkI.accentName == 'Custom', onTap: () => setState(() => lkI.setAccent('Custom'))),
          ],
        ),
        changed: lkI.accentName != defaultAccentFor[themeName],
        reset: () {
          lkI.accents[themeName] = defaultAccentFor[themeName]!;
          lkI.save();
        },
      ),
      if (lkI.accentName == 'Custom')
        _row(
          'Custom accent',
          Row(
            children: [
              for (var i = 0; i < 3; i++) ...[
                swatch(
                  i < lkI.accent.length ? lkI.accent[i] : lkI.accent.last,
                  onTap: () async {
                    final c = await pickColour(
                      context,
                      i < lkI.accent.length ? lkI.accent[i] : lkI.accent.last,
                      i == 2 ? 'Accent: third colour (optional)' : 'Accent colour ${i + 1}',
                    );
                    if (c != null) setState(() => lkI.setCustomAccent(i, c));
                  },
                ),
                const SizedBox(width: 8),
              ],
              swatch(lkI.acc, w: 120, g: lkI.grad),
              const SizedBox(width: 8),
              if ((lkI.customAccents[themeName]?.length ?? 0) > 2)
                Btn.ghost(
                  'Use two colours',
                  dense: true,
                  onTap: () {
                    lkI.customAccents[themeName] = lkI.customAccents[themeName]!.take(2).toList();
                    lkI.save();
                    setState(() {});
                  },
                ),
            ],
          ),
        ),
      const SizedBox(height: 6),
      Text('$themeName colours', style: ts(w: FontWeight.w600)),
      Text('Click a colour to change it. Changes are saved into the theme.', style: ts(c: tk.sec, size: 12)),
      const SizedBox(height: 6),
      Wrap(
        spacing: 18,
        runSpacing: 2,
        children: [
          for (final e in tokenLabels.entries)
            SizedBox(
              width: 330,
              child: Row(
                children: [
                  swatch(
                    tokens[e.key]!,
                    onTap: () async {
                      final c = await pickColour(context, tokens[e.key]!, '$themeName · ${e.value}');
                      if (c != null) setState(() => lkI.setToken(e.key, c));
                    },
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      e.value,
                      style: ts(c: ov.containsKey(e.key) ? tk.text : tk.sec),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(colorHex(tokens[e.key]!), style: ts(mono: true, size: 11.5, c: tk.faint)),
                  _resetBtn(ov.containsKey(e.key) && colorHex(base[e.key]!) != ov[e.key], () => lkI.resetToken(e.key)),
                ],
              ),
            ),
        ],
      ),
      const SizedBox(height: 10),
      _row(
        'App size',
        _scale(lkI.appScale, 0.8, 1.6, 'the whole window', (v) => lkI.appScale = v),
        changed: lkI.appScale != Look.defaultAppScale,
        reset: () {
          lkI.appScale = Look.defaultAppScale;
          lkI.save();
        },
      ),
      _row(
        'Reader controls size',
        _scale(lkI.readerScale, 0.8, 2.0, 'bars, panels and status line', (v) => lkI.readerScale = v),
        changed: lkI.readerScale != Look.defaultReaderScale,
        reset: () {
          lkI.readerScale = Look.defaultReaderScale;
          lkI.save();
        },
      ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        children: [
          Btn(
            'Reset $themeName to default',
            icon: Icons.restart_alt,
            onTap: lkI.themeEdited(themeName)
                ? () {
                    lkI.resetTheme(themeName);
                    setState(() {});
                    toast('$themeName is back to its default colours');
                  }
                : null,
          ),
        ],
      ),
    ];
  }

  List<Widget> _folders() {
    final fs = Settings.I.folders;
    return [
      for (final f in fs)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: tk.line)),
          ),
          child: Row(
            children: [
              Icon(
                Directory(f.path).existsSync() ? Icons.folder_outlined : Icons.folder_off_outlined,
                size: 16,
                color: Directory(f.path).existsSync() ? tk.sec : tk.warn,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(f.path, style: ts(mono: true, size: 12), overflow: TextOverflow.ellipsis),
                    ),
                    if (!Directory(f.path).existsSync()) Text('  can\'t be reached', style: ts(c: tk.warn, size: 12)),
                  ],
                ),
              ),
              Seg<Kind>(
                value: f.kind,
                items: const [(Kind.book, 'Books'), (Kind.ln, 'Light novels')],
                onChanged: (v) {
                  f.kind = v;
                  Settings.I.save();
                  Library.I.reapplyFolders();
                },
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Books from downloaded packs. "Collections hidden" in the library hides them all at once.',
                child: Row(
                  children: [
                    Checkbox(
                      value: f.collection,
                      onChanged: (v) {
                        f.collection = v ?? false;
                        Settings.I.save();
                        Library.I.reapplyFolders();
                      },
                    ),
                    Text('Collection', style: ts(c: tk.sec)),
                  ],
                ),
              ),
              IconBtn(
                Icons.close,
                tooltip: 'Take this folder off the list (nothing on disk is touched)',
                onTap: () {
                  fs.remove(f);
                  Settings.I.save();
                  Library.I.startWatching();
                  Library.I.scan();
                },
              ),
            ],
          ),
        ),
      const SizedBox(height: 8),
      Row(
        children: [
          Btn(
            'Add folder…',
            icon: Icons.create_new_folder_outlined,
            onTap: () async {
              final d = await FilePicker.getDirectoryPath(dialogTitle: 'Add a folder of books');
              if (d == null) return;
              if (!fs.any((x) => x.path == d)) fs.add(LibFolder(d));
              Settings.I.save();
              Library.I.startWatching();
              Library.I.scan();
            },
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text('Sable never moves, renames or changes your books.', style: ts(c: tk.faint, size: 12)),
          ),
        ],
      ),
    ];
  }

  Widget _storageRow((String, String, bool, bool) pl) {
    final size = sizes[pl.$2];
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tk.line)),
      ),
      child: Row(
        children: [
          SizedBox(width: 280, child: Text(pl.$1, style: ts())),
          Expanded(
            child: Text(
              pl.$2,
              style: ts(mono: true, size: 12, c: tk.sec),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 100,
            child: Text(size == null ? 'Working out…' : humanSize(size), style: ts(c: tk.sec, tab: true)),
          ),
          Btn.ghost(
            'Open folder',
            dense: true,
            onTap: () {
              if (Platform.isWindows) Process.run('explorer.exe', [pl.$2]);
            },
          ),
          if (pl.$3) Btn.ghost('Move…', dense: true, onTap: () => _move(pl.$1, pl.$2)),
          if (pl.$4)
            Btn.ghost(
              'Clear',
              dense: true,
              onTap: () async {
                if (await confirm(
                  context,
                  'Clear ${pl.$1.toLowerCase()}?',
                  'This frees ${size == null ? 'some space' : humanSize(size)}. It\'s made again when needed.',
                  confirmLabel: 'Clear',
                )) {
                  await _clear(pl.$2);
                  _measure();
                }
              },
            ),
        ],
      ),
    );
  }

  Widget _reset(String part, String what, FutureOr<void> Function() run) {
    return Btn(
      'Reset ${part.toLowerCase()}',
      kind: BtnKind.dangerGhost,
      onTap: () async {
        if (await confirm(context, 'Reset ${part.toLowerCase()}?', what, confirmLabel: 'Reset ${part.toLowerCase()}', danger: true)) {
          await run();
          toast('$part reset');
          _measure();
        }
      },
    );
  }

  Future<void> _clear(String dir) async {
    final d = Directory(dir);
    if (!await d.exists()) return;
    await for (final e in d.list()) {
      try {
        await e.delete(recursive: true);
      } catch (_) {}
    }
    Covers.I.version++;
    Library.I.changed();
  }

  /// Copies everything with progress, checks the copy, switches, then removes the old copy.
  Future<void> _move(String what, String from) async {
    if (Jobs.I.current != null) {
      toast('Moving waits until nothing else is running', ToastKind.info);
      return;
    }
    final to = await FilePicker.getDirectoryPath(dialogTitle: 'Move $what to…');
    if (to == null) return;
    final dest = p.join(to, p.basename(from) == 'covers' || p.basename(from) == 'books' ? 'Cache' : 'Sable');
    final isData = from == AppPaths.I.data;
    final isCache = from == AppPaths.I.thumbs || from == AppPaths.I.bookCache;
    final src = isCache ? AppPaths.I.cache : from;
    Jobs.I.add(
      Job('Moving $what', (job) async {
        final files = await Directory(src).list(recursive: true).where((e) => e is File).cast<File>().toList();
        final total = await Future.wait(files.map((f) => f.length())).then((l) => l.fold<int>(0, (a, b) => a + b));
        job.unit = 'bytes';
        job.progress(0, total: total, detail: 'Copying to $dest');
        var done = 0;
        for (final f in files) {
          if (!await job.checkpoint()) return null;
          final rel = p.relative(f.path, from: src);
          final out = File(p.join(dest, rel));
          await out.parent.create(recursive: true);
          await f.copy(out.path);
          done += await f.length();
          job.progress(done, detail: '${humanSize(done)} of ${humanSize(total)}');
        }
        job.setDetail('Checking the copy');
        for (final f in files) {
          final out = File(p.join(dest, p.relative(f.path, from: src)));
          if (!await out.exists() || await out.length() != await f.length()) {
            throw Exception('The copy of ${p.basename(f.path)} doesn\'t match, so nothing was switched.');
          }
        }
        if (isCache) {
          writeStringSafelySync(p.join(AppPaths.I.data, 'cache_location.json'), jsonEncode({'cache': dest}));
          final old = AppPaths.I.cache;
          AppPaths.I.cache = dest;
          AppPaths.I.ensureCache();
          try {
            await Directory(old).delete(recursive: true);
          } catch (_) {}
          Covers.I.version++;
          return '$what moved to $dest';
        }
        if (isData) {
          final base = Platform.environment['LOCALAPPDATA'] ?? from;
          writeStringSafelySync(AppPaths.pointerFileFor(p.join(base, 'Sable')), jsonEncode({'data': dest, 'old': from}));
          AppLog.I.info('Data copied to $dest. It switches over next time Sable starts.');
          return '$what copied. Restart Sable to finish the move.';
        }
        return null;
      }, canPause: true),
    );
    setState(() {});
  }
}

/// A settings group, with a rough idea of how tall it is.
class _GroupBox extends StatelessWidget {
  const _GroupBox({required this.weight, required this.child, this.title = '', this.desc = ''});
  final int weight;
  final Widget child;
  final String title;
  final String desc;
  @override
  Widget build(BuildContext context) => child;
}

/// Settings → Opening ebooks (Windows): register Sable, then let Windows pick it.
class _DefaultApp extends StatefulWidget {
  const _DefaultApp();
  @override
  State<_DefaultApp> createState() => _DefaultAppState();
}

class _DefaultAppState extends State<_DefaultApp> {
  bool? registered;
  @override
  void initState() {
    super.initState();
    FileAssoc.registered().then((v) {
      if (mounted) setState(() => registered = v);
    });
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Btn.primary(
        'Make Sable the default for ebooks',
        icon: Icons.open_in_new,
        onTap: () async {
          final ok = await FileAssoc.register();
          if (mounted) setState(() => registered = ok);
          if (!ok) {
            toast('Couldn\'t register Sable with Windows');
            return;
          }
          toast('In Windows settings, choose Sable for .epub (and .mobi, .azw3)');
          await FileAssoc.openDefaultApps();
        },
      ),
      Text(
        registered == null ? '' : (registered! ? 'Sable is offered for EPUB, MOBI and AZW3 files.' : 'Not set up yet.'),
        style: ts(c: tk.faint, size: 12),
      ),
    ],
  );
}

/// Settings → Phone, on the PC: the pairing code and the paired phones.
class _PcPhone extends StatefulWidget {
  const _PcPhone();
  @override
  State<_PcPhone> createState() => _PcPhoneState();
}

class _PcPhoneState extends State<_PcPhone> {
  List<String> addresses = [];

  @override
  void initState() {
    super.initState();
    SyncServer.I.ensureLoaded();
    SyncServer.I.addresses().then((a) {
      if (mounted) setState(() => addresses = a);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncServer.I,
      builder: (context, _) {
        final sv = SyncServer.I;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Switch(value: sv.enabled, onChanged: (v) => sv.setEnabled(v)),
                const SizedBox(width: 8),
                Expanded(child: Text('Let my phone sync with this PC over WiFi', style: ts())),
              ],
            ),
            if (sv.enabled) ...[
              const SizedBox(height: 6),
              Text(
                sv.problem ?? 'Ready. Sable on the phone finds this PC by itself when both are on the same WiFi.',
                style: ts(c: sv.problem == null ? tk.sec : tk.danger, size: 12.5),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text('Pairing code', style: ts(c: tk.sec)),
                  const SizedBox(width: 14),
                  SelectableText(
                    sv.code.length == 6 ? '${sv.code.substring(0, 3)} ${sv.code.substring(3)}' : sv.code,
                    style: ts(size: 24, w: FontWeight.w700, mono: true, c: lk.acc),
                  ),
                  const SizedBox(width: 14),
                  Btn.ghost('New code', icon: Icons.refresh, dense: true, onTap: sv.newCode),
                ],
              ),
              Text(
                'On the phone: Settings → Connection → Connect to your PC, then type this code. Each code works once.',
                style: ts(c: tk.faint, size: 12),
              ),
              const SizedBox(height: 8),
              Text(
                addresses.isEmpty
                    ? 'This PC isn\'t on a network right now.'
                    : 'This PC\'s address: ${addresses.join(', ')} (type it on the phone if it doesn\'t find the PC).',
                style: ts(c: tk.sec, size: 12.5),
              ),
              Text(
                'The first time, Windows may ask whether Sable can use the network: allow it for private networks.',
                style: ts(c: tk.faint, size: 12),
              ),
              const SizedBox(height: 12),
              Text('Paired phones', style: ts(w: FontWeight.w600)),
              const SizedBox(height: 4),
              if (sv.phones.isEmpty) Text('None yet.', style: ts(c: tk.faint)),
              for (final ph in sv.phones)
                Row(
                  children: [
                    Icon(Icons.phone_android, size: 16, color: tk.sec),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${ph.name} · last seen ${ph.lastSeen == 0 ? 'never' : '${dateText(ph.lastSeen)} ${timeText(ph.lastSeen)}'}',
                        style: ts(),
                      ),
                    ),
                    Btn.ghost(
                      'Unpair',
                      dense: true,
                      onTap: () async {
                        if (await confirm(
                          context,
                          'Unpair ${ph.name}?',
                          'It can\'t sync with this PC until it\'s paired again with a new code. Nothing is deleted on either side.',
                          confirmLabel: 'Unpair',
                        )) {
                          sv.removePhone(ph);
                        }
                      },
                    ),
                  ],
                ),
              if (sv.lastSyncText.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('Last sync: ${sv.lastSyncText} · ${timeText(sv.lastSyncAt)}', style: ts(c: tk.faint, size: 12)),
              ],
            ],
          ],
        );
      },
    );
  }
}
