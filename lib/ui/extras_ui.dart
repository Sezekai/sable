import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pasteboard/pasteboard.dart';

import '../core/db.dart';
import '../core/extras.dart';
import '../core/jobs.dart';
import '../core/library.dart';
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
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!, style: ts(c: tk.danger)),
            ],
          ],
        ),
        actions: [
          if (widget.canReset) Btn.ghost('Use the book\'s own', onTap: () => Navigator.pop(context, '')),
          if (!isPhone) Btn('Paste', icon: Icons.content_paste, onTap: busy ? null : _paste),
          Btn('Choose a picture…', icon: Icons.folder_open_outlined, onTap: busy
              ? null
              : () => _use(() async {
                    final r = await FilePicker.pickFiles(type: FileType.image);
                    final f = r.firstOrNull;
                    if (f == null) throw 'No picture chosen.';
                    final Uint8List bytes = await f.xFile.readAsBytes();
                    return CustomCovers.save(bytes);
                  })),
          Btn('Cancel', onTap: () => Navigator.pop(context)),
        ],
      ),
    );
  }
}

/// Make a series from these books, or edit one: its name and the order of
/// its books (drag to reorder). Returns true when saved.
Future<bool> seriesDialog(BuildContext context, {required String name, required List<Volume> volumes, bool isNew = false}) async {
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
                          SizedBox(width: 30, child: Text('${i + 1}', style: ts(c: tk.faint, tab: true))),
                          Expanded(child: Text(v.primary.displayTitle, style: ts(), overflow: TextOverflow.ellipsis)),
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
  if (ok != true) return false;
  Library.I.makeSeries(ctl.text.trim(), order);
  return true;
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
              Expanded(child: Text('Copies of this book', style: ts(w: FontWeight.w600))),
              Btn.ghost('Separate', dense: true, tooltip: 'These aren\'t the same book: show them apart', onTap: () => Library.I.separate(v)),
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
                    child: Text(f.format.toUpperCase(), style: ts(size: 11, w: FontWeight.w700, c: tk.sec)),
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
