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
import '../core/settings.dart';
import 'look.dart';
import 'reader_page.dart';
import 'widgets.dart';

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
      listenable: Settings.I,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Settings', style: ts(size: 15, w: FontWeight.w700)),
            const SizedBox(width: 10),
            Text('Changes apply straight away.', style: ts(c: tk.sec)),
          ]),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(children: [
              _group('Library folders', 'Where your books are. Light novel folders treat each folder inside as a series. Collections can be hidden from the library in one click.', [
                ..._folders(),
              ]),
              _group('Look', 'The app and the reading page follow the theme.', [
                _row('Theme', Seg<String>(
                  value: Look.I.theme,
                  items: const [('OLED black', 'OLED black'), ('Starlight', 'Starlight')],
                  onChanged: (v) => setState(() => Look.I.setTheme(v)),
                )),
                _row('Accent', Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final e in accentPresets.entries)
                    Tooltip(
                      message: e.key,
                      child: GestureDetector(
                        onTap: () => setState(() => Look.I.setAccent(e.key)),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Container(
                            width: 44,
                            height: 22,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(colors: e.value.length == 1 ? [e.value.first, e.value.first] : e.value),
                              borderRadius: BorderRadius.circular(11),
                              border: Border.all(color: Look.I.accentName == e.key ? tk.text : Colors.transparent, width: 2),
                            ),
                          ),
                        ),
                      ),
                    ),
                ])),
              ]),
              _group('Reader', 'Reading settings can also be changed while reading (the Aa button).', [
                _row('Font', Drop<String>(
                  value: Settings.I.style.font,
                  width: 220,
                  items: [for (final f in readingFonts) (f, fontLabel(f))],
                  onChanged: (v) {
                    Settings.I.style.font = v;
                    Settings.I.save();
                  },
                )),
                _row('Pages at once', Seg<PageLayout>(
                  value: Settings.I.style.layout,
                  items: const [(PageLayout.auto, 'Auto (two when the window is wide)'), (PageLayout.one, 'One'), (PageLayout.two, 'Two')],
                  onChanged: (v) {
                    Settings.I.style.layout = v;
                    Settings.I.save();
                  },
                )),
                _check('Skip volumes already read when moving to the next volume', Settings.I.skipRead, (v) => Settings.I.skipRead = v),
                _check('Show PDFs with dark pages (inverts their colours)', Settings.I.pdfDarkPages, (v) => Settings.I.pdfDarkPages = v),
                _row('Idle after', Row(children: [
                  Drop<int>(
                    value: Settings.I.idleMinutes,
                    items: const [(1, '1 minute'), (2, '2 minutes'), (3, '3 minutes'), (5, '5 minutes'), (10, '10 minutes'), (30, '30 minutes')],
                    onChanged: (v) {
                      Settings.I.idleMinutes = v;
                      Settings.I.save();
                    },
                  ),
                  const SizedBox(width: 10),
                  Flexible(child: Text('Time with no page turns isn\'t counted as reading.', style: ts(c: tk.faint, size: 12))),
                ])),
                const SizedBox(height: 4),
                Text(
                    Platform.isWindows
                        ? (ReaderWeb.runtimeVersion == null
                            ? (ReaderWeb.checked ? 'The WebView2 Runtime isn\'t installed, so EPUB and MOBI books can\'t be opened.' : 'The book engine starts when you open a book.')
                            : 'Book engine: Microsoft Edge WebView2 ${ReaderWeb.runtimeVersion}')
                        : '',
                    style: ts(c: ReaderWeb.checked && ReaderWeb.runtimeVersion == null ? tk.warn : tk.faint, size: 12)),
              ]),
              _group('Library', 'How the library behaves.', [
                _check('Show a reading progress line on covers', Settings.I.progressLine, (v) => Settings.I.progressLine = v),
                _check('Show "Continue reading" at the top of the library', Settings.I.showContinue, (v) => Settings.I.showContinue = v),
                _check('Watch the folders and add new books by themselves', Settings.I.watchFolders, (v) {
                  Settings.I.watchFolders = v;
                  Library.I.startWatching();
                }),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 6, children: [
                  Btn('Scan the library', icon: Icons.refresh, onTap: Library.I.scan),
                  Btn('Read file names again', icon: Icons.text_fields, tooltip: 'Applies the series and volume rules again. Your edits are kept.',
                      onTap: () {
                    Library.I.reapplyFolders();
                    toast('File names read again');
                  }),
                  Btn('Make missing covers', icon: Icons.image_outlined, onTap: Covers.I.queueMissing),
                ]),
              ]),
              _group('Storage', 'Everywhere Sable keeps things, and how much space each uses.', [
                for (final pl in _places()) _storageRow(pl),
              ]),
              _group('Reset', 'Each part asks first and says exactly what is cleared. Your files are never deleted.', [
                Wrap(spacing: 8, runSpacing: 8, children: [
                  _reset('Settings', 'All settings go back to their defaults. Your library, history and themes stay.', () {
                    Settings.I.resetToDefaults();
                  }),
                  _reset('Library', 'Sable forgets every book, with its ratings, favourites, tags, bookmarks and history. Your files stay on disk.', () {
                    Db.I.resetLibrary();
                    Library.I.load();
                  }),
                  _reset('History', 'All reading sessions, read counts and reading positions are cleared. Books, ratings, favourites, tags and bookmarks stay.', () {
                    Db.I.resetHistory();
                    Library.I.load();
                  }),
                  _reset('Look', 'The theme and accent go back to OLED black with the violet to pink accent.', () {
                    Look.I.resetToDefault();
                  }),
                  _reset('Cover cache', 'Covers are made again when needed.', () async {
                    await _clear(AppPaths.I.thumbs);
                  }),
                  _reset('Book cache', 'Books copied out of ZIPs are removed; they\'re copied again when opened.', () async {
                    await _clear(AppPaths.I.bookCache);
                  }),
                ]),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _group(String title, String desc, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: tk.panel, borderRadius: BorderRadius.circular(lk.rPanel), border: Border.all(color: tk.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: ts(w: FontWeight.w700)),
          Text(desc, style: ts(c: tk.sec, size: 12)),
          const SizedBox(height: 10),
          ...children,
        ]),
      );

  Widget _row(String label, Widget child) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(width: 160, child: Text(label, style: ts(c: tk.sec))),
          Flexible(child: child),
        ]),
      );

  Widget _check(String label, bool v, ValueChanged<bool> on) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(children: [
          Checkbox(value: v, onChanged: (x) {
            on(x ?? false);
            Settings.I.save();
          }),
          const SizedBox(width: 4),
          Flexible(child: Text(label, style: ts())),
        ]),
      );

  List<Widget> _folders() {
    final fs = Settings.I.folders;
    return [
      for (final f in fs)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tk.line))),
          child: Row(children: [
            Icon(Directory(f.path).existsSync() ? Icons.folder_outlined : Icons.folder_off_outlined, size: 16,
                color: Directory(f.path).existsSync() ? tk.sec : tk.warn),
            const SizedBox(width: 8),
            Expanded(
              child: Row(children: [
                Flexible(child: Text(f.path, style: ts(mono: true, size: 12), overflow: TextOverflow.ellipsis)),
                if (!Directory(f.path).existsSync()) Text('  can\'t be reached', style: ts(c: tk.warn, size: 12)),
              ]),
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
              child: Row(children: [
                Checkbox(
                    value: f.collection,
                    onChanged: (v) {
                      f.collection = v ?? false;
                      Settings.I.save();
                      Library.I.reapplyFolders();
                    }),
                Text('Collection', style: ts(c: tk.sec)),
              ]),
            ),
            IconBtn(Icons.close, tooltip: 'Take this folder off the list (nothing on disk is touched)', onTap: () {
              fs.remove(f);
              Settings.I.save();
              Library.I.startWatching();
              Library.I.scan();
            }),
          ]),
        ),
      const SizedBox(height: 8),
      Row(children: [
        Btn('Add folder…', icon: Icons.create_new_folder_outlined, onTap: () async {
          final d = await FilePicker.getDirectoryPath(dialogTitle: 'Add a folder of books');
          if (d == null) return;
          if (!fs.any((x) => x.path == d)) fs.add(LibFolder(d));
          Settings.I.save();
          Library.I.startWatching();
          Library.I.scan();
        }),
        const SizedBox(width: 10),
        Flexible(child: Text('Sable never moves, renames or changes your books.', style: ts(c: tk.faint, size: 12))),
      ]),
    ];
  }

  Widget _storageRow((String, String, bool, bool) pl) {
    final size = sizes[pl.$2];
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tk.line))),
      child: Row(children: [
        SizedBox(width: 280, child: Text(pl.$1, style: ts())),
        Expanded(child: Text(pl.$2, style: ts(mono: true, size: 12, c: tk.sec), overflow: TextOverflow.ellipsis)),
        SizedBox(width: 100, child: Text(size == null ? 'Working out…' : humanSize(size), style: ts(c: tk.sec, tab: true))),
        Btn.ghost('Open folder', dense: true, onTap: () {
          if (Platform.isWindows) Process.run('explorer.exe', [pl.$2]);
        }),
        if (pl.$3) Btn.ghost('Move…', dense: true, onTap: () => _move(pl.$1, pl.$2)),
        if (pl.$4)
          Btn.ghost('Clear', dense: true, onTap: () async {
            if (await confirm(context, 'Clear ${pl.$1.toLowerCase()}?',
                'This frees ${size == null ? 'some space' : humanSize(size)}. It\'s made again when needed.', confirmLabel: 'Clear')) {
              await _clear(pl.$2);
              _measure();
            }
          }),
      ]),
    );
  }

  Widget _reset(String part, String what, FutureOr<void> Function() run) {
    return Btn('Reset ${part.toLowerCase()}', kind: BtnKind.dangerGhost, onTap: () async {
      if (await confirm(context, 'Reset ${part.toLowerCase()}?', what, confirmLabel: 'Reset ${part.toLowerCase()}', danger: true)) {
        await run();
        toast('$part reset');
        _measure();
      }
    });
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
    Jobs.I.add(Job('Moving $what', (job) async {
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
    }, canPause: true));
    setState(() {});
  }
}
