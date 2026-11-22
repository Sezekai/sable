import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/db.dart';
import '../core/downloads.dart';
import '../core/jobs.dart';
import '../core/library.dart';
import '../core/sync_client.dart';
import '../core/sync_server.dart' show syncPort;
import 'app.dart';
import 'book_page.dart';
import 'history_page.dart';
import 'library_page.dart';
import 'look.dart';
import 'settings_page.dart';
import 'stats_page.dart';
import 'widgets.dart';

// =====================================================================
// The phone's frame: the screen, a bar of what's running, and tabs.
// =====================================================================

class PhoneShell extends StatelessWidget {
  const PhoneShell({super.key});

  /// Android's back gesture: close what's open, then go to the library,
  /// then leave the app.
  bool _back() {
    final nav = Nav.I;
    if (nav.detail != null) {
      nav.canGoBack ? nav.back() : nav.closeDetail();
      return true;
    }
    if (nav.page != PageId.library) {
      nav.go(PageId.library);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Nav.I,
      builder: (context, _) {
        final nav = Nav.I;
        return PopScope(
          canPop: nav.detail == null && nav.page == PageId.library,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _back();
          },
          child: Scaffold(
            backgroundColor: tk.ground,
            body: Stack(
              children: [
                if (lk.starlight) const Positioned.fill(child: StarField()),
                SafeArea(
                  bottom: false,
                  child: Column(
                    children: [
                      Expanded(child: _content(nav)),
                      const PhoneStatusStrip(),
                      const _Tabs(),
                    ],
                  ),
                ),
                const ToastLayer(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _content(Nav nav) {
    switch (nav.page) {
      case PageId.library:
        if (nav.detail != null) {
          return nav.detailIsSeries
              ? SeriesPage(key: ValueKey('s${nav.detail}'), seriesKey: nav.detail!)
              : BookPage(key: ValueKey('b${nav.detail}'), volumeKey: nav.detail!);
        }
        return const LibraryPage();
      case PageId.history:
        return const HistoryPage();
      case PageId.stats:
        return const StatsPage();
      case PageId.downloads:
        return const DownloadsPage();
      case PageId.settings:
        return const SettingsPage();
    }
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs();
  @override
  Widget build(BuildContext context) {
    final nav = Nav.I;
    Widget tab(IconData icon, String label, PageId id, {int badge = 0}) {
      final on = nav.page == id;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (on && id == PageId.library && nav.detail != null) {
              nav.closeDetail();
            } else {
              nav.go(id);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Stack(clipBehavior: Clip.none, children: [
                Container(
                  width: 52,
                  height: 28,
                  decoration: BoxDecoration(
                    color: on ? lk.tint(tk.raised, 0.25) : null,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, size: 21, color: on ? lk.acc : tk.sec),
                ),
                if (badge > 0)
                  Positioned(
                    right: 4,
                    top: -3,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(color: lk.acc, borderRadius: BorderRadius.circular(8)),
                      child: Text('$badge', style: ts(size: 10, w: FontWeight.w700, c: lk.onAcc)),
                    ),
                  ),
              ]),
              const SizedBox(height: 3),
              Text(label, style: ts(size: 11.5, c: on ? tk.text : tk.sec, w: on ? FontWeight.w600 : null)),
            ]),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: lk.starlight ? tk.panel.withValues(alpha: 0.9) : tk.panel,
        border: Border(top: BorderSide(color: tk.line)),
      ),
      child: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: Listenable.merge([Downloads.I, Nav.I]),
          builder: (_, _) => Row(children: [
            tab(Icons.auto_stories_outlined, 'Library', PageId.library),
            tab(Icons.history, 'History', PageId.history),
            tab(Icons.insights_outlined, 'Stats', PageId.stats),
            tab(Icons.download_outlined, 'Downloads', PageId.downloads, badge: Downloads.I.queue.length),
            tab(Icons.settings_outlined, 'Settings', PageId.settings),
          ]),
        ),
      ),
    );
  }
}

/// A thin bar above the tabs while something runs: sync or downloads, with a
/// progress bar, percentage, time taken and time left.
class PhoneStatusStrip extends StatelessWidget {
  const PhoneStatusStrip({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Jobs.I, Downloads.I]),
      builder: (context, _) {
        final j = Jobs.I.current;
        final d = Downloads.I;
        String? title, detail;
        double? f;
        Duration? elapsed, left;
        VoidCallback? onTap;
        if (j != null) {
          title = j.name;
          detail = j.detail;
          f = j.fraction;
          elapsed = j.elapsed;
          left = j.timeLeft;
        } else if (d.queue.isNotEmpty) {
          final running = d.queue.where((q) => q.state == DlState.running).firstOrNull;
          title = d.paused
              ? 'Downloads paused'
              : running == null
                  ? 'Downloads waiting for the PC'
                  : 'Downloading ${d.queue.length} book${d.queue.length == 1 ? '' : 's'}';
          detail = running?.title ?? '';
          f = d.batchFraction;
          elapsed = d.batchElapsed;
          left = d.batchTimeLeft;
          onTap = () => Nav.I.go(PageId.downloads);
        }
        if (title == null) return const SizedBox.shrink();
        return GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 7, 14, 8),
            decoration: BoxDecoration(
              color: tk.panel,
              border: Border(top: BorderSide(color: tk.line)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(
                    detail == null || detail.isEmpty ? title : '$title · $detail',
                    style: ts(size: 12.5, w: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(f == null ? '' : '${(f * 100).floor()}%', style: ts(size: 12.5, tab: true, w: FontWeight.w600)),
              ]),
              const SizedBox(height: 5),
              Progress(value: f, height: 4),
              const SizedBox(height: 4),
              Text(
                '${formatDuration(elapsed ?? Duration.zero)} so far'
                '${left == null ? ' · working out time left' : ' · ${humanLeft(left)}'}',
                style: ts(size: 11.5, c: tk.faint, tab: true),
              ),
            ]),
          ),
        );
      },
    );
  }
}

// =====================================================================
// The sync button in the library's header.
// =====================================================================

class SyncButton extends StatelessWidget {
  const SyncButton({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncClient.I,
      builder: (context, _) {
        final c = SyncClient.I;
        final icon = !c.paired
            ? Icons.cloud_off_outlined
            : c.syncing
                ? Icons.sync
                : c.online
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_outlined;
        final tip = !c.paired
            ? 'Not connected to the PC. Tap to set up.'
            : c.syncing
                ? 'Syncing…'
                : c.online
                    ? 'Synced with ${c.pcName} ${c.lastSyncAt == 0 ? '' : timeAgo(c.lastSyncAt)}. Tap to sync now.'
                    : '${c.pcName} not reachable. Tap to try now.';
        return IconBtn(icon, size: 20, tooltip: tip, color: c.paired && c.online ? lk.acc : null, onTap: () {
          if (!c.paired) {
            Nav.I.go(PageId.settings);
            WidgetsBinding.instance.addPostFrameCallback((_) => pairDialog(context));
            return;
          }
          syncNow();
        });
      },
    );
  }
}

String timeAgo(int sec) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(sec * 1000));
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return dateText(sec);
}

/// Sync now, saying how it went.
Future<void> syncNow() async {
  try {
    await SyncClient.I.sync();
    final c = SyncClient.I;
    toast(c.lastResult, c.lastFailed ? ToastKind.error : ToastKind.ok);
    if (c.online) Downloads.I.retryWaiting();
  } catch (e) {
    toast('$e', ToastKind.error);
  }
}

// =====================================================================
// Pairing with the PC.
// =====================================================================

Future<void> pairDialog(BuildContext context) => showDialog(context: context, builder: (_) => const _PairDialog());

class _PairDialog extends StatefulWidget {
  const _PairDialog();
  @override
  State<_PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<_PairDialog> {
  List<FoundPc> found = [];
  bool looking = true;
  bool working = false;
  String? error;
  final hostCtl = TextEditingController();
  final codeCtl = TextEditingController();
  final nameCtl = TextEditingController(text: SyncClient.I.deviceName);

  @override
  void initState() {
    super.initState();
    _look();
  }

  Future<void> _look() async {
    setState(() => looking = true);
    final f = await SyncClient.I.discover();
    if (!mounted) return;
    setState(() {
      found = f;
      looking = false;
      if (f.isNotEmpty && hostCtl.text.isEmpty) hostCtl.text = f.first.host;
    });
  }

  Future<void> _pair() async {
    final h = hostCtl.text.trim();
    if (h.isEmpty || codeCtl.text.trim().length < 6) {
      setState(() => error = 'Pick the PC (or type its address) and type the 6-digit code shown on the PC.');
      return;
    }
    setState(() {
      working = true;
      error = null;
    });
    try {
      var host = h, port = syncPort;
      if (h.contains(':')) {
        host = h.split(':').first;
        port = int.tryParse(h.split(':').last) ?? syncPort;
      }
      final name = nameCtl.text.trim();
      await SyncClient.I.pair(host, port, codeCtl.text, device: name.isEmpty ? null : name);
      if (!mounted) return;
      Navigator.pop(context);
      toast('Paired with ${SyncClient.I.pcName}. Bringing in the library…');
      unawaited(syncNow());
    } on SyncError catch (e) {
      setState(() => error = e.message);
    } catch (e) {
      setState(() => error = 'Couldn\'t reach Sable on $h. Is the PC on, with Sable open, on the same WiFi? ($e)');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: 'Connect to your PC',
      width: 460,
      body: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(
            'On the PC, open Sable → Settings → Phone. It shows a 6-digit code. The phone and PC need to be on the same WiFi.',
            style: ts(c: tk.sec),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Text('PCs found', style: ts(w: FontWeight.w600)),
            const Spacer(),
            if (looking)
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            else
              Btn.ghost('Look again', icon: Icons.refresh, dense: true, onTap: _look),
          ]),
          const SizedBox(height: 6),
          if (!looking && found.isEmpty)
            Text('None found. Type the PC\'s address below (shown on the PC under Settings → Phone).',
                style: ts(c: tk.faint, size: 12.5)),
          for (final pc in found)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Pill('${pc.name} · ${pc.host}', active: hostCtl.text == pc.host, onTap: () => setState(() => hostCtl.text = pc.host)),
            ),
          const SizedBox(height: 10),
          Text('PC address', style: ts(c: tk.sec, size: 12.5)),
          const SizedBox(height: 4),
          Field(controller: hostCtl, hint: '192.168.1.20', mono: true),
          const SizedBox(height: 10),
          Text('Code from the PC', style: ts(c: tk.sec, size: 12.5)),
          const SizedBox(height: 4),
          Field(controller: codeCtl, hint: '123456', mono: true, onSubmitted: (_) => _pair()),
          const SizedBox(height: 10),
          Text('This phone\'s name (shown on the PC)', style: ts(c: tk.sec, size: 12.5)),
          const SizedBox(height: 4),
          Field(controller: nameCtl, hint: 'Phone'),
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(error!, style: ts(c: tk.danger)),
          ],
        ]),
      ),
      actions: [
        Btn('Cancel', onTap: () => Navigator.pop(context)),
        Btn.primary(working ? 'Connecting…' : 'Connect', onTap: working ? null : _pair),
      ],
    );
  }
}

/// Settings → Connection, on the phone.
class PhoneConnection extends StatelessWidget {
  const PhoneConnection({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncClient.I,
      builder: (context, _) {
        final c = SyncClient.I;
        if (!c.paired) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Not connected. Pair with Sable on your PC to bring your library here.', style: ts(c: tk.sec)),
            const SizedBox(height: 10),
            Btn.primary('Connect to your PC', icon: Icons.link, onTap: () => pairDialog(context)),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(c.online ? Icons.cloud_done_outlined : Icons.cloud_outlined, size: 18, color: c.online ? lk.acc : tk.sec),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${c.pcName} · ${c.host}', style: ts(w: FontWeight.w600), overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            c.lastSyncAt == 0 ? 'Not synced yet' : 'Last synced ${timeAgo(c.lastSyncAt)}',
            style: ts(c: tk.sec, size: 12.5),
          ),
          if (c.lastResult.isNotEmpty)
            Text(c.lastResult, style: ts(c: c.lastFailed ? tk.danger : tk.faint, size: 12.5)),
          const SizedBox(height: 4),
          ListenableBuilder(
            listenable: Library.I,
            builder: (_, _) {
              final n = Db.I.outbox().length;
              return Text(n == 0 ? 'Nothing waiting to send' : '$n change${n == 1 ? '' : 's'} waiting to send',
                  style: ts(c: tk.faint, size: 12.5));
            },
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            Btn.primary(c.syncing ? 'Syncing…' : 'Sync now', icon: Icons.sync, onTap: c.syncing ? null : syncNow),
            Btn('Pair again', icon: Icons.link, onTap: () => pairDialog(context)),
            Btn.ghost('Disconnect', icon: Icons.link_off, onTap: () async {
              if (await confirm(context, 'Disconnect from ${c.pcName}?',
                  'The library, history and downloaded books stay on this phone. Changes made from now on are kept and sent when you connect again.',
                  confirmLabel: 'Disconnect')) {
                c.unpair();
              }
            }),
          ]),
          const SizedBox(height: 6),
          Text('Syncs by itself when the app opens, comes back to the front, and every 5 minutes while open.',
              style: ts(c: tk.faint, size: 12)),
        ]);
      },
    );
  }
}

// =====================================================================
// Downloads
// =====================================================================

/// Download / remove buttons for one book (on its page).
class DownloadBtn extends StatelessWidget {
  const DownloadBtn(this.book, {super.key});
  final Book book;
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Downloads.I,
      builder: (context, _) {
        final d = Downloads.I;
        final it = d.itemFor(book);
        if (d.isDone(book)) {
          return Btn('On this phone · Remove', icon: Icons.download_done, onTap: () async {
            if (await confirm(context, 'Remove from this phone?',
                'The download is removed from the phone to free space. The book stays on the PC and in your library.',
                confirmLabel: 'Remove')) {
              d.remove([book]);
            }
          });
        }
        if (it != null) {
          return Btn(
            it.state == DlState.running ? 'Downloading ${(it.fraction * 100).floor()}% · Cancel' : 'Queued · Cancel',
            icon: Icons.close,
            onTap: () => d.cancel(book.uid),
          );
        }
        return Btn('Download (${humanSize(book.size)})', icon: Icons.download_outlined, onTap: () {
          if (!SyncClient.I.paired) {
            toast('Connect to your PC first (Settings → Connection).', ToastKind.error);
            return;
          }
          d.add([book]);
          toast('Downloading ${book.cardTitle}');
        });
      },
    );
  }
}

/// Download buttons for a series (all, or just the unread ones).
class SeriesDownloads extends StatelessWidget {
  const SeriesDownloads(this.vols, {super.key});
  final List<Volume> vols;
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Downloads.I,
      builder: (context, _) {
        final d = Downloads.I;
        final books = [for (final v in vols) v.primary];
        final onPhone = books.where(d.isDone).length;
        final queued = books.where(d.isQueued).length;
        final unread = [for (final v in vols) if (!v.isRead) v.primary].where((b) => !d.isDone(b) && !d.isQueued(b)).toList();
        final rest = books.where((b) => !d.isDone(b) && !d.isQueued(b)).toList();
        int size(List<Book> l) => l.fold(0, (a, b) => a + b.size);
        void go(List<Book> l) {
          if (!SyncClient.I.paired) {
            toast('Connect to your PC first (Settings → Connection).', ToastKind.error);
            return;
          }
          d.add(l);
          toast('Downloading ${l.length} book${l.length == 1 ? '' : 's'}');
        }

        return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (rest.isNotEmpty) Btn('Download all ${rest.length} (${humanSize(size(rest))})', icon: Icons.download_outlined, onTap: () => go(rest)),
          if (unread.isNotEmpty && unread.length != rest.length)
            Btn('Download unread ${unread.length} (${humanSize(size(unread))})', icon: Icons.download_outlined, onTap: () => go(unread)),
          if (queued > 0) Btn('$queued downloading · Cancel', icon: Icons.close, onTap: () {
            for (final b in books) {
              d.cancel(b.uid);
            }
          }),
          if (onPhone > 0)
            Btn('$onPhone on this phone · Remove', icon: Icons.download_done, onTap: () async {
              if (await confirm(context, 'Remove this series\' downloads?',
                  'The $onPhone downloaded book${onPhone == 1 ? '' : 's'} are removed from the phone. They stay on the PC and in your library.',
                  confirmLabel: 'Remove')) {
                d.remove(books.where(d.isDone));
              }
            }),
        ]);
      },
    );
  }
}

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Downloads.I, Library.I]),
      builder: (context, _) {
        final d = Downloads.I;
        final done = d.done.values.toList()..sort((a, b) => b.at.compareTo(a.at));
        return ListView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
          children: [
            Row(children: [
              Text('Downloads', style: ts(size: 18, w: FontWeight.w700)),
              const SizedBox(width: 8),
              Text('${done.length} on this phone · ${humanSize(d.usedBytes)}', style: ts(c: tk.faint, tab: true)),
            ]),
            const SizedBox(height: 4),
            Text('Pick books or series to download from their pages. Nothing is downloaded by itself.',
                style: ts(c: tk.faint, size: 12.5)),
            const SizedBox(height: 12),
            if (d.queue.isNotEmpty) ...[
              PanelBox(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text(
                        '${d.paused ? 'Paused' : 'Downloading'} ${d.queue.length} book${d.queue.length == 1 ? '' : 's'} · ${humanSize(d.queuedBytes)} left',
                        style: ts(w: FontWeight.w600),
                      ),
                    ),
                    Text('${(d.batchFraction * 100).floor()}%', style: ts(w: FontWeight.w600, tab: true)),
                  ]),
                  const SizedBox(height: 6),
                  Progress(value: d.batchFraction),
                  const SizedBox(height: 5),
                  Text(
                    '${formatDuration(d.batchElapsed)} so far · '
                    '${d.batchTimeLeft == null ? 'working out time left' : humanLeft(d.batchTimeLeft!)}',
                    style: ts(c: tk.faint, size: 12, tab: true),
                  ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, children: [
                    Btn(d.paused ? 'Resume' : 'Pause', icon: d.paused ? Icons.play_arrow : Icons.pause, dense: true,
                        onTap: () => d.setPaused(!d.paused)),
                    Btn.ghost('Cancel all', icon: Icons.close, dense: true, onTap: d.cancelAll),
                  ]),
                ]),
              ),
              const SizedBox(height: 10),
              for (final it in d.queue) _QueueRow(it),
              const SizedBox(height: 16),
            ],
            if (done.isEmpty && d.queue.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 40),
                child: EmptyState(
                  icon: Icons.download_outlined,
                  text: 'No books on this phone yet. Open a book or series and tap Download to read it away from the PC.',
                ),
              ),
            if (done.isNotEmpty) ...[
              Row(children: [
                Text('On this phone', style: ts(w: FontWeight.w600, c: tk.sec)),
                const Spacer(),
                Btn.ghost('Remove all', dense: true, onTap: () async {
                  if (await confirm(context, 'Remove all downloads?',
                      'All ${done.length} downloaded books (${humanSize(d.usedBytes)}) are removed from this phone. They stay on the PC and in your library.',
                      confirmLabel: 'Remove all', danger: true)) {
                    d.removeAll();
                  }
                }),
              ]),
              const SizedBox(height: 6),
              for (final x in done) _DoneRow(x),
            ],
          ],
        );
      },
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow(this.it);
  final DownloadItem it;
  @override
  Widget build(BuildContext context) {
    final running = it.state == DlState.running;
    final left = it.timeLeft;
    final status = switch (it.state) {
      DlState.running => '${humanSize(it.received)} of ${humanSize(it.total)} · '
          '${humanSize(it.speed)}/s · ${formatDuration(it.elapsed)} so far'
          '${left == null ? '' : ' · ${humanLeft(left)}'}',
      DlState.queued => 'Queued · ${humanSize(it.total)}',
      DlState.waiting => '${it.error ?? 'Waiting for the PC'} · carries on after the next sync',
      DlState.failed => 'Failed: ${it.error}',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(it.title, style: ts(w: FontWeight.w600), overflow: TextOverflow.ellipsis)),
              if (running) Text('${(it.fraction * 100).floor()}%', style: ts(tab: true, w: FontWeight.w600)),
            ]),
            const SizedBox(height: 4),
            Progress(value: running || it.received > 0 ? it.fraction : 0, height: 4),
            const SizedBox(height: 3),
            Text(status, style: ts(size: 12, c: it.state == DlState.failed ? tk.danger : tk.faint, tab: true)),
          ]),
        ),
        IconBtn(Icons.close, tooltip: 'Cancel', onTap: () => Downloads.I.cancel(it.uid)),
      ]),
    );
  }
}

class _DoneRow extends StatelessWidget {
  const _DoneRow(this.x);
  final Downloaded x;
  @override
  Widget build(BuildContext context) {
    final b = Library.I.books.where((b) => b.uid == x.uid).firstOrNull;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tk.line.withValues(alpha: 0.55)))),
      child: Row(children: [
        if (b != null)
          GestureDetector(
            onTap: () {
              final v = Library.I.volumeOf(b);
              if (v != null) Nav.I.openVolume(v);
            },
            child: SizedBox(width: 34, height: 50, child: ClipRRect(borderRadius: BorderRadius.circular(3), child: BookCover(book: b, width: 34))),
          ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(x.title, style: ts(w: FontWeight.w600), overflow: TextOverflow.ellipsis),
            Text('${humanSize(x.size)} · downloaded ${dateText(x.at)}', style: ts(size: 12, c: tk.faint)),
          ]),
        ),
        IconBtn(Icons.delete_outline, tooltip: 'Remove from this phone', onTap: () {
          if (b != null) {
            Downloads.I.remove([b]);
          } else {
            Downloads.I.forget(x.uid);
          }
        }),
      ]),
    );
  }
}

// =====================================================================
// Opening a book on the phone
// =====================================================================

/// The file to read: the download if there is one, otherwise fetched from the
/// PC now (with progress). Null if it can't be had.
Future<String?> phoneBookFile(BuildContext context, Book b) async {
  final local = Downloads.I.fileFor(b);
  if (local != null) return local;
  if (!SyncClient.I.paired) {
    toast('This book isn\'t downloaded. Connect to your PC to read it, or download it first.', ToastKind.error);
    return null;
  }
  return showDialog<String>(context: context, barrierDismissible: false, builder: (_) => _FetchDialog(b));
}

class _FetchDialog extends StatefulWidget {
  const _FetchDialog(this.b);
  final Book b;
  @override
  State<_FetchDialog> createState() => _FetchDialogState();
}

class _FetchDialogState extends State<_FetchDialog> {
  int got = 0, total = 0;
  final started = DateTime.now();
  String? error;
  bool gone = false;

  @override
  void initState() {
    super.initState();
    _go();
  }

  Future<void> _go() async {
    try {
      final path = await Downloads.I.fetchForReading(widget.b, (g, t) {
        if (!mounted || gone) return;
        setState(() {
          got = g;
          total = t;
        });
      });
      if (mounted && !gone) Navigator.pop(context, path);
    } catch (e) {
      if (mounted && !gone) {
        setState(() => error = e is SocketException
            ? 'The PC can\'t be reached, and this book isn\'t downloaded. Download it at home to read it here.'
            : '$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = total <= 0 ? null : got / total;
    final secs = DateTime.now().difference(started).inMilliseconds / 1000;
    final left = f == null || f <= 0 || secs < 0.5 ? null : Duration(seconds: (secs / f * (1 - f)).round());
    return AppDialog(
      title: 'Opening from the PC',
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text('${widget.b.cardTitle} isn\'t downloaded, so it\'s read from the PC.', style: ts(c: tk.sec)),
        const SizedBox(height: 12),
        if (error != null)
          Text(error!, style: ts(c: tk.danger))
        else ...[
          Row(children: [
            Expanded(child: Progress(value: f)),
            const SizedBox(width: 10),
            Text(f == null ? '' : '${(f * 100).floor()}%', style: ts(tab: true, w: FontWeight.w600)),
          ]),
          const SizedBox(height: 6),
          Text(
            '${humanSize(got)}${total > 0 ? ' of ${humanSize(total)}' : ''} · ${formatDuration(Duration(milliseconds: (secs * 1000).round()))} so far'
            '${left == null ? '' : ' · ${humanLeft(left)}'}',
            style: ts(c: tk.faint, size: 12.5, tab: true),
          ),
        ],
      ]),
      actions: [
        Btn(error == null ? 'Cancel' : 'Close', onTap: () {
          gone = true;
          Navigator.pop(context);
        }),
      ],
    );
  }
}

/// Phone reader: the system bars hide while reading.
void phoneReaderMode(bool reading) {
  SystemChrome.setEnabledSystemUIMode(reading ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
}
