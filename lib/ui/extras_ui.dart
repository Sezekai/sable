import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pasteboard/pasteboard.dart';

import '../core/db.dart';
import '../core/extras.dart';
import '../core/jobs.dart';
import '../core/library.dart';
import '../core/parse.dart';
import '../core/platform.dart';
import 'widgets.dart';

/// Type or change a description. Returns the new text ('' to clear), or null if cancelled.
Future<String?> descriptionDialog(BuildContext context, String title, String? current) {
  final ctl = TextEditingController(text: current ?? '');
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black54,
    builder: (c) => AppDialog(
      title: title,
      width: 640,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Leave it empty to go back to the book\'s own (or the one found online).', style: ts(c: tk.sec, size: 12.5)),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: tk.field,
              border: Border.all(color: tk.line),
              borderRadius: BorderRadius.circular(lk.rControl),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: TextField(
              controller: ctl,
              autofocus: true,
              minLines: 8,
              maxLines: 16,
              style: ts(),
              cursorColor: lk.acc,
              decoration: const InputDecoration(border: InputBorder.none, isDense: true),
            ),
          ),
        ],
      ),
      actions: [
        Btn('Cancel', onTap: () => Navigator.pop(c)),
        Btn.primary('Save', onTap: () => Navigator.pop(c, ctl.text)),
      ],
    ),
  );
}

/// Pick a new cover: drop a picture, paste one (or a copied picture address),
/// or choose a file. Returns the cover key, '' to go back to the book's own,
/// or null if cancelled.
Future<String?> coverDialog(BuildContext context, String title, {bool canReset = true}) =>
    showDialog<String>(context: context, barrierColor: Colors.black54, builder: (_) => _CoverDialog(title, canReset));

class _CoverDialog extends StatefulWidget {
  const _CoverDialog(this.title, this.canReset);
  final String title;
  final bool canReset;
  @override
  State<_CoverDialog> createState() => _CoverDialogState();
}

class _CoverDialogState extends State<_CoverDialog> {
  bool over = false, busy = false;
  String? error;
  final _focus = FocusNode();

  Future<void> _use(Future<String?> Function() get) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final key = await get();
      if (!mounted) return;
      if (key == null) {
        setState(() => error = 'That isn\'t a picture Sable can use (JPG, PNG, WebP, GIF or BMP).');
      } else {
        Navigator.pop(context, key);
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _paste() => _use(() async {
    // A picture copied from a web page or an image editor…
    final bytes = await Pasteboard.image;
    if (bytes != null && bytes.isNotEmpty) return CustomCovers.save(bytes);
    // …a picture file copied in Explorer…
    final files = await Pasteboard.files();
    if (files.isNotEmpty) return CustomCovers.save(await File(files.first).readAsBytes());
    // …or a picture's address.
    final text = (await Clipboard.getData('text/plain'))?.text ?? '';
    if (text.startsWith('http')) return CustomCovers.fromUrl(text);
    return null;
  });

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final drop = Container(
      height: 170,
      decoration: BoxDecoration(
        color: over ? lk.tint(tk.field, 0.2) : tk.field,
        border: Border.all(color: over ? lk.acc : tk.line, width: over ? 2 : 1),
        borderRadius: BorderRadius.circular(lk.rPanel),
      ),
      alignment: Alignment.center,
      child: busy
          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.image_outlined, size: 32, color: tk.sec),
                const SizedBox(height: 8),
                Text(isPhone ? 'Choose a picture' : 'Drop a picture here, or press Ctrl+V to paste one', style: ts(c: tk.sec)),
              ],
            ),
    );
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (n, e) {
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.keyV && HardwareKeyboard.instance.isControlPressed) {
          _paste();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AppDialog(
        title: widget.title,
        width: 520,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isPhone)
              drop
            else
              DropTarget(
                onDragEntered: (_) => setState(() => over = true),
                onDragExited: (_) => setState(() => over = false),
                onDragDone: (d) {
                  setState(() => over = false);
                  if (d.files.isEmpty) return;
                  _use(() async => CustomCovers.save(await d.files.first.readAsBytes()));
                },
                child: drop,
              ),
            if (error != null) ...[const SizedBox(height: 8), Text(error!, style: ts(c: tk.danger))],
          ],
        ),
        actions: [
          if (widget.canReset) Btn.ghost('Use the book\'s own', onTap: () => Navigator.pop(context, '')),
          if (!isPhone) Btn('Paste', icon: Icons.content_paste, onTap: busy ? null : _paste),
          Btn(
            'Choose a picture…',
            icon: Icons.folder_open_outlined,
            onTap: busy
                ? null
                : () => _use(() async {
                    final r = await FilePicker.pickFiles(type: FileType.image);
                    final f = r.firstOrNull;
                    if (f == null) throw 'No picture chosen.';
                    final Uint8List bytes = await f.xFile.readAsBytes();
                    return CustomCovers.save(bytes);
                  }),
          ),
          Btn('Cancel', onTap: () => Navigator.pop(context)),
        ],
      ),
    );
  }
}

/// Make a series from these books, or edit one: its name and the order of
/// its books (drag to reorder). Returns true when saved.
/// Returns the series' key (it changes with the name), or null if cancelled.
Future<String?> seriesDialog(BuildContext context, {required String name, required List<Volume> volumes, bool isNew = false}) async {
  final fromKey = isNew ? null : normKey(name);
  final ctl = TextEditingController(text: name);
  final order = [...volumes];
  final ok = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black54,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AppDialog(
        title: isNew ? 'Make a series' : 'Edit the series',
        width: 560,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Name', style: ts(c: tk.sec, size: 12.5)),
            const SizedBox(height: 4),
            Field(controller: ctl, autofocus: isNew, hint: 'Series name'),
            const SizedBox(height: 12),
            Text('Order (drag to change; the first is volume 1)', style: ts(c: tk.sec, size: 12.5)),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                itemCount: order.length,
                onReorderItem: (a, b) => set(() => order.insert(b, order.removeAt(a))),
                itemBuilder: (_, i) {
                  final v = order[i];
                  return ReorderableDragStartListener(
                    key: ValueKey(v.key),
                    index: i,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(color: tk.raised, borderRadius: BorderRadius.circular(lk.rControl)),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 30,
                            child: Text('${i + 1}', style: ts(c: tk.faint, tab: true)),
                          ),
                          Expanded(
                            child: Text(v.primary.displayTitle, style: ts(), overflow: TextOverflow.ellipsis),
                          ),
                          Icon(Icons.drag_indicator, size: 18, color: tk.faint),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        actions: [
          Btn('Cancel', onTap: () => Navigator.pop(c, false)),
          Btn.primary('Save', onTap: () => Navigator.pop(c, ctl.text.trim().isNotEmpty)),
        ],
      ),
    ),
  );
  if (ok != true) return null;
  Library.I.makeSeries(ctl.text.trim(), order, fromKey: fromKey);
  return normKey(ctl.text.trim());
}

/// Copies of one book (formats or versions): pick which opens first, read any.
class CopiesBox extends StatelessWidget {
  const CopiesBox({super.key, required this.volume, required this.onRead});
  final Volume volume;
  final void Function(Book b) onRead;
  @override
  Widget build(BuildContext context) {
    final v = volume;
    final def = v.primary;
    return PanelBox(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Copies of this book', style: ts(w: FontWeight.w600)),
              ),
              Btn.ghost(
                'Separate',
                dense: true,
                tooltip: 'These aren\'t the same book: show them apart',
                onTap: () => Library.I.separate(v),
              ),
            ],
          ),
          Text('Reading progress is shared between them. The default opens when you press Read.', style: ts(c: tk.faint, size: 12)),
          const SizedBox(height: 6),
          for (final f in v.files)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  IconBtn(
                    f.id == def.id ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    size: 18,
                    color: f.id == def.id ? lk.acc : null,
                    tooltip: 'Open this copy by default',
                    onTap: () => Library.I.setPreferred(v, f),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: tk.raised, borderRadius: BorderRadius.circular(6)),
                    child: Text(
                      f.format.toUpperCase(),
                      style: ts(size: 11, w: FontWeight.w700, c: tk.sec),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${f.fileName} · ${humanSize(f.size)}',
                      style: ts(c: f.id == def.id ? tk.text : tk.sec, size: 12.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Btn.ghost('Read', dense: true, icon: Icons.auto_stories_outlined, onTap: () => onRead(f)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------- looking things up by hand ----------------

/// The search part of the look-up dialogs: title, author, where to look.
class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.title, required this.author, required this.source, required this.onSource, required this.onSearch});
  final TextEditingController title;
  final TextEditingController author;
  final FindSource source;
  final ValueChanged<FindSource> onSource;
  final VoidCallback onSearch;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            flex: 3,
            child: Field(controller: title, hint: 'Title (change it to search again)', onSubmitted: (_) => onSearch()),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Field(controller: author, hint: 'Author (optional)', onSubmitted: (_) => onSearch()),
          ),
          const SizedBox(width: 8),
          Btn.primary('Search', icon: Icons.search, onTap: onSearch),
        ],
      ),
      const SizedBox(height: 8),
      Seg<FindSource>(value: source, items: [for (final s in FindSource.values) (s, s.label)], onChanged: onSource),
    ],
  );
}

/// Finds descriptions online and lets you pick one. Returns the text, or null.
Future<String?> findDescriptionDialog(BuildContext context, {required String title, String? author}) {
  final t = TextEditingController(text: title);
  final a = TextEditingController(text: author ?? '');
  var source = FindSource.all;
  List<Found>? results;
  var busy = false;
  var started = false;
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black54,
    builder: (c) => StatefulBuilder(
      builder: (c, set) {
        Future<void> run() async {
          set(() => busy = true);
          final r = await Lookup.search(t.text, a.text, source: source);
          if (c.mounted) {
            set(() {
              results = r;
              busy = false;
            });
          }
        }

        if (!started) {
          started = true;
          Future.microtask(run);
        }
        return AppDialog(
          title: 'Find a description',
          width: 760,
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SearchBar(title: t, author: a, source: source, onSource: (v) => set(() => source = v), onSearch: run),
              const SizedBox(height: 10),
              SizedBox(
                height: 420,
                child: busy
                    ? Center(
                        child: Text('Searching…', style: ts(c: tk.sec)),
                      )
                    : (results == null || results!.isEmpty)
                    ? Center(
                        child: Text(
                          'Nothing found. Try a shorter title, without the volume or subtitle, or another service.',
                          style: ts(c: tk.sec),
                        ),
                      )
                    : ListView(
                        children: [
                          for (final f in results!)
                            Hoverable(
                              builder: (h) => GestureDetector(
                                onTap: () => Navigator.pop(c, f.text),
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: Container(
                                    margin: const EdgeInsets.only(bottom: 6),
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: h ? tk.raised : tk.panel,
                                      borderRadius: BorderRadius.circular(lk.rControl + 2),
                                      border: Border.all(color: tk.line),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                f.author.isEmpty ? f.title : '${f.title} · ${f.author}',
                                                style: ts(w: FontWeight.w600),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            Text(f.source, style: ts(c: tk.faint, size: 11.5)),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          f.text!,
                                          maxLines: 4,
                                          overflow: TextOverflow.ellipsis,
                                          style: ts(c: tk.sec, size: 12.5),
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
            ],
          ),
          actions: [Btn('Cancel', onTap: () => Navigator.pop(c))],
        );
      },
    ),
  );
}

/// Finds covers online and lets you pick one; it's saved as a cover. Returns its key, or null.
Future<String?> findCoverDialog(BuildContext context, {required String title, String? author}) {
  final t = TextEditingController(text: title);
  final a = TextEditingController(text: author ?? '');
  var source = FindSource.all;
  List<Found>? results;
  var busy = false;
  var saving = false;
  var started = false;
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black54,
    builder: (c) => StatefulBuilder(
      builder: (c, set) {
        Future<void> run() async {
          set(() => busy = true);
          final r = await Lookup.search(t.text, a.text, source: source, covers: true);
          if (c.mounted) {
            set(() {
              results = r;
              busy = false;
            });
          }
        }

        Future<void> pick(Found f) async {
          set(() => saving = true);
          final k = await CustomCovers.fromUrl(f.image!) ?? (f.thumb == null ? null : await CustomCovers.fromUrl(f.thumb!));
          if (!c.mounted) return;
          set(() => saving = false);
          if (k == null) {
            toast('That picture couldn\'t be downloaded. Try another.', ToastKind.error);
            return;
          }
          Navigator.pop(c, k);
        }

        if (!started) {
          started = true;
          Future.microtask(run);
        }
        return AppDialog(
          title: 'Find a cover',
          width: 860,
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SearchBar(title: t, author: a, source: source, onSource: (v) => set(() => source = v), onSearch: run),
              const SizedBox(height: 10),
              SizedBox(
                height: 460,
                child: busy || saving
                    ? Center(
                        child: Text(saving ? 'Saving the cover…' : 'Searching…', style: ts(c: tk.sec)),
                      )
                    : (results == null || results!.isEmpty)
                    ? Center(
                        child: Text('Nothing found. Try a shorter title, or another service.', style: ts(c: tk.sec)),
                      )
                    : GridView.builder(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 150,
                          mainAxisExtent: 262,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                        itemCount: results!.length,
                        itemBuilder: (_, i) {
                          final f = results![i];
                          return Hoverable(
                            builder: (h) => GestureDetector(
                              onTap: () => pick(f),
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    AspectRatio(
                                      aspectRatio: 2 / 3,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(lk.rControl),
                                          border: Border.all(color: h ? lk.acc : tk.line, width: h ? 2 : 1),
                                          color: tk.raised,
                                        ),
                                        clipBehavior: Clip.antiAlias,
                                        child: Image.network(
                                          f.thumb ?? f.image!,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, _, _) => Center(child: Icon(Icons.broken_image_outlined, color: tk.faint)),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      f.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: ts(size: 11.5, w: FontWeight.w600),
                                    ),
                                    Text(f.source, style: ts(size: 10.5, c: tk.faint)),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
          actions: [Btn('Cancel', onTap: () => Navigator.pop(c))],
        );
      },
    ),
  );
}

/// Frames a cover: drag to move it, use the mouse wheel (or pinch) to zoom.
/// Returns "x,y,zoom", '' for the whole picture, or null if cancelled.
Future<String?> reframeDialog(BuildContext context, {required File file, String? pos}) {
  var x = 0.0, y = 0.0, z = 1.0;
  if (pos != null && pos.isNotEmpty) {
    final p = pos.split(',');
    x = double.tryParse(p.first) ?? 0;
    y = p.length > 1 ? double.tryParse(p[1]) ?? 0 : 0;
    z = p.length > 2 ? double.tryParse(p[2]) ?? 1 : 1;
  }
  const w = 300.0, h = 450.0;
  var startZ = 1.0;
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black54,
    builder: (c) => StatefulBuilder(
      builder: (c, set) {
        String value() => '${x.toStringAsFixed(3)},${y.toStringAsFixed(3)},${z.toStringAsFixed(3)}';
        void zoomBy(double f) => set(() => z = (z * f).clamp(1.0, 5.0));
        return AppDialog(
          title: 'Frame the cover',
          width: 380,
          onEnter: () => Navigator.pop(c, value()),
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Drag to move it. Scroll (or pinch) to zoom in and out.', style: ts(c: tk.sec, size: 12.5)),
              const SizedBox(height: 12),
              Listener(
                onPointerSignal: (e) {
                  if (e is PointerScrollEvent) {
                    GestureBinding.instance.pointerSignalResolver.register(e, (_) => zoomBy(e.scrollDelta.dy < 0 ? 1.08 : 1 / 1.08));
                  }
                },
                child: GestureDetector(
                  onScaleStart: (_) => startZ = z,
                  onScaleUpdate: (d) => set(() {
                    if (d.scale != 1) z = (startZ * d.scale).clamp(1.0, 5.0);
                    // Moving the picture: the further in, the finer each step.
                    final k = 1 / z;
                    x = (x - d.focalPointDelta.dx / (w / 2) * k).clamp(-1.0, 1.0);
                    y = (y - d.focalPointDelta.dy / (h / 2) * k).clamp(-1.0, 1.0);
                  }),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.move,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(lk.rPanel),
                      child: SizedBox(
                        width: w,
                        height: h,
                        child: ClipRect(
                          child: Transform.scale(
                            scale: z,
                            alignment: Alignment(x, y),
                            child: Image.file(
                              file,
                              fit: BoxFit.cover,
                              alignment: Alignment(x, y),
                              gaplessPlayback: true,
                              width: w,
                              height: h,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            Btn.ghost('Reset', onTap: () => Navigator.pop(c, '')),
            Btn('Cancel', onTap: () => Navigator.pop(c)),
            Btn.primary('Save', onTap: () => Navigator.pop(c, value())),
          ],
        );
      },
    ),
  );
}

/// What to do with a cover.
enum CoverAction { find, change, frame, reset }

Future<CoverAction?> coverMenu(BuildContext context, {required bool custom}) => showDialog<CoverAction>(
  context: context,
  barrierColor: Colors.black54,
  builder: (c) {
    Widget item(CoverAction a, IconData icon, String label, String sub) => Hoverable(
      builder: (h) => GestureDetector(
        onTap: () => Navigator.pop(c, a),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: h ? tk.raised : null, borderRadius: BorderRadius.circular(lk.rControl)),
            child: Row(
              children: [
                Icon(icon, size: 20, color: tk.sec),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: ts(w: FontWeight.w600)),
                      Text(sub, style: ts(c: tk.faint, size: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return AppDialog(
      title: 'Cover',
      width: 440,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          item(CoverAction.find, Icons.travel_explore, 'Find online', 'Choose from Apple Books, Google Books and Open Library'),
          item(CoverAction.change, Icons.image_outlined, 'Use a picture', 'Paste, drag one in, or choose a file'),
          item(CoverAction.frame, Icons.crop, 'Frame it', 'Drag and zoom to choose which part shows'),
          if (custom) item(CoverAction.reset, Icons.restart_alt, 'Use the book\'s own', 'Back to the cover in the file'),
        ],
      ),
      actions: [Btn('Cancel', onTap: () => Navigator.pop(c))],
    );
  },
);
