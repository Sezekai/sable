import 'dart:async';

import 'db.dart';
import 'library.dart';
import 'log.dart';
import 'settings.dart';

/// Records one reading session: active time (idle time isn't counted),
/// where reading started and stopped, pages read, and finishing the book.
class ReadTracker {
  ReadTracker(this.book) {
    startedAt = nowSec();
    fromPct = book.progress;
    lastPct = book.progress;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  final Book book;
  late final int startedAt;
  late final double fromPct;
  double lastPct = 0;
  int activeSeconds = 0;
  DateTime _lastActivity = DateTime.now();
  final Set<int> _pagesSeen = {};
  bool completed = false;
  bool _closed = false;
  late final Timer _ticker;
  bool paused = false;

  void _tick() {
    if (paused) return;
    final idle = DateTime.now().difference(_lastActivity).inSeconds;
    if (idle < Settings.I.idleMinutes * 60) activeSeconds++;
  }

  void activity() => _lastActivity = DateTime.now();

  /// The reader moved. [pct] is 0…1, [position] a CFI or page number,
  /// [page] the current location (1,500-byte page or PDF page).
  void moved(double pct, String position, int page) {
    activity();
    lastPct = pct;
    _pagesSeen.add(page);
    book
      ..progress = pct
      ..position = position
      ..lastReadAt = nowSec();
    Db.I.updateReading(book);
  }

  /// Called once the end of the book is reached.
  bool finish() {
    if (completed) return false;
    completed = true;
    final now = nowSec();
    Db.I.addCompletion(book.id, now);
    book
      ..readCount += 1
      ..manualRead = false
      ..firstCompletedAt = book.firstCompletedAt == 0 ? now : book.firstCompletedAt
      ..lastCompletedAt = now;
    Db.I.updateReading(book);
    AppLog.I.info('Finished ${book.cardTitle} ${book.volumeText}'.trim());
    Library.I.changed();
    return true;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _ticker.cancel();
    final ended = nowSec();
    // When a finished book is closed at its end, the next read starts it again from the top.
    if (completed && lastPct >= 0.995) {
      book
        ..progress = 0
        ..position = '';
    }
    book.timeSpent += activeSeconds;
    Db.I.updateReading(book);
    if (activeSeconds >= 10 || completed) {
      Db.I.addSession(
        bookId: book.id,
        startedAt: startedAt,
        endedAt: ended,
        activeSeconds: activeSeconds,
        fromPct: fromPct,
        toPct: lastPct,
        pagesRead: _pagesSeen.length,
        completed: completed,
      );
    }
    // The reader is closing while the window is being rebuilt; update the library just after.
    Future(() => Library.I.changed());
  }
}
