import 'db.dart';

/// What the PC and the phone exchange when they sync.
///
/// The phone sends its outbox (each change it made since the last sync, in
/// order). The PC applies them with [applyOps], then sends back a snapshot of
/// all reading records ([buildSnapshot]), which the phone takes as its own
/// ([applySnapshot]). Changes the phone made while that was happening are
/// applied again on top, so nothing is lost.
///
/// Rules when both sides changed the same thing:
/// - Reading place, rating, favourite and read marks: the latest change wins.
/// - Sessions, finishes and bookmarks are records, each with its own id, so
///   both sides' records are kept (never doubled).
/// - Reading time, times read and first/last finished are worked out from the
///   records, so they add up the same on both.
const syncTables = ['books', 'tags', 'sessions', 'completions', 'book_tags', 'bookmarks'];

/// Increase when the sync messages change in a way an older app can't follow.
const syncVersion = 1;

Map<String, Object?> buildSnapshot(Db db) {
  final out = <String, Object?>{'version': syncVersion, 'at': nowSec()};
  for (final t in syncTables) {
    final rs = db.raw.select('SELECT * FROM $t');
    out[t] = {
      'cols': rs.columnNames,
      'rows': [for (final r in rs.rows) r],
    };
  }
  return out;
}

/// Replaces this device's reading records with [snap] (from the PC).
void applySnapshot(Db db, Map<String, dynamic> snap) {
  db.raw.execute('BEGIN');
  try {
    for (final t in syncTables.reversed) {
      db.raw.execute('DELETE FROM $t');
    }
    for (final t in syncTables) {
      final m = snap[t] as Map<String, dynamic>?;
      if (m == null) continue;
      final cols = (m['cols'] as List).cast<String>();
      // Only the columns this version of the app knows about.
      final mine = db.raw.select('PRAGMA table_info($t)').map((r) => r['name'] as String).toSet();
      final keep = [for (var i = 0; i < cols.length; i++) if (mine.contains(cols[i])) i];
      if (keep.isEmpty) continue;
      final st = db.raw.prepare(
          'INSERT OR REPLACE INTO $t(${keep.map((i) => cols[i]).join(',')}) VALUES(${List.filled(keep.length, '?').join(',')})');
      for (final row in (m['rows'] as List)) {
        final r = row as List;
        st.execute([for (final i in keep) r[i]]);
      }
      st.close();
    }
    db.raw.execute('COMMIT');
  } catch (_) {
    db.raw.execute('ROLLBACK');
    rethrow;
  }
}

/// Applies changes sent by the phone. Returns how many were applied (changes
/// already seen, or for books that no longer exist, are skipped).
int applyOps(Db db, List<Map<String, dynamic>> ops) {
  final was = db.recordChanges;
  db.recordChanges = false; // applying isn't a new change
  var applied = 0;
  final touched = <int>{};
  db.raw.execute('BEGIN');
  try {
    for (final op in ops) {
      if (_apply(db, op, touched)) applied++;
    }
    for (final id in touched) {
      _recount(db, id);
    }
    db.raw.execute('COMMIT');
  } catch (_) {
    db.raw.execute('ROLLBACK');
    rethrow;
  } finally {
    db.recordChanges = was;
  }
  return applied;
}

int? _bookId(Db db, String? uid) {
  if (uid == null) return null;
  final r = db.raw.select('SELECT id FROM books WHERE uid=?', [uid]);
  return r.isEmpty ? null : r.first['id'] as int;
}

bool _exists(Db db, String table, Object? uid) =>
    db.raw.select('SELECT 1 FROM $table WHERE uid=?', [uid]).isNotEmpty;

int _tagId(Db db, String name, {int? color}) {
  final r = db.raw.select('SELECT id FROM tags WHERE name=?', [name]);
  if (r.isNotEmpty) return r.first['id'] as int;
  final idx = db.raw.select('SELECT COALESCE(MAX(sort_index),0)+1 AS n FROM tags').first['n'] as int;
  db.raw.execute('INSERT INTO tags(name,color,sort_index) VALUES(?,?,?)', [name, color ?? 0xff9b86ff, idx]);
  return db.raw.lastInsertRowId;
}

int _b(Object? v) => v == true || v == 1 ? 1 : 0;
double _d(Object? v) => (v as num?)?.toDouble() ?? 0;

bool _apply(Db db, Map<String, dynamic> op, Set<int> touched) {
  final kind = op['kind'] as String;
  final d = (op['data'] as Map?)?.cast<String, dynamic>() ?? const {};
  final atSec = ((op['at'] as num?)?.toInt() ?? nowMs()) ~/ 1000;
  final id = _bookId(db, op['book'] as String?);
  switch (kind) {
    case 'state':
      if (id == null) return false;
      final cur = db.raw.select('SELECT updated_at FROM books WHERE id=?', [id]).first['updated_at'] as int? ?? 0;
      if (atSec < cur) return false; // changed more recently on this side
      db.raw.execute(
          '''UPDATE books SET rating=?, favourite=?, position=?, progress=?, last_read_at=MAX(last_read_at, ?),
          manual_read=?, updated_at=? WHERE id=?''',
          [_d(d['rating']), _b(d['favourite']), d['position'] ?? '', _d(d['progress']), d['last_read_at'] ?? 0,
            _b(d['manual_read']), atSec, id]);
      return true;
    case 'edits':
      if (id == null) return false;
      final cur = db.raw.select('SELECT updated_at FROM books WHERE id=?', [id]).first['updated_at'] as int? ?? 0;
      if (atSec < cur) return false;
      db.raw.execute(
          'UPDATE books SET user_title=?, user_author=?, user_series=?, user_volume=?, user_kind=?, updated_at=? WHERE id=?',
          [d['user_title'], d['user_author'], d['user_series'], d['user_volume'], d['user_kind'], atSec, id]);
      return true;
    case 'session':
      if (id == null || _exists(db, 'sessions', d['uid'])) return false;
      db.raw.execute(
          '''INSERT INTO sessions(uid,book_id,started_at,ended_at,active_seconds,from_pct,to_pct,pages_read,
          completed,device,source) VALUES(?,?,?,?,?,?,?,?,?,?,?)''',
          [d['uid'], id, d['started_at'], d['ended_at'], d['active_seconds'] ?? 0, _d(d['from_pct']), _d(d['to_pct']),
            d['pages_read'] ?? 0, _b(d['completed']), d['device'] ?? 'Phone', 'phone']);
      db.raw.execute('UPDATE books SET time_spent = time_spent + ?, last_read_at = MAX(last_read_at, ?) WHERE id=?',
          [d['active_seconds'] ?? 0, d['ended_at'] ?? 0, id]);
      return true;
    case 'session_del':
      final r = db.raw.select('SELECT book_id, active_seconds FROM sessions WHERE uid=?', [d['uid']]);
      if (r.isEmpty) return false;
      db.raw.execute('UPDATE books SET time_spent = MAX(0, time_spent - ?) WHERE id=?',
          [r.first['active_seconds'], r.first['book_id']]);
      db.raw.execute('DELETE FROM sessions WHERE uid=?', [d['uid']]);
      return true;
    case 'completion':
      if (id == null || _exists(db, 'completions', d['uid'])) return false;
      db.raw.execute('INSERT INTO completions(uid,book_id,at,manual,source) VALUES(?,?,?,?,?)',
          [d['uid'], id, d['at'], _b(d['manual']), 'phone']);
      touched.add(id);
      return true;
    case 'uncomplete':
      if (id == null) return false;
      db.raw.execute('DELETE FROM completions WHERE book_id=? AND manual=1', [id]);
      touched.add(id);
      return true;
    case 'bookmark_add':
      if (id == null || _exists(db, 'bookmarks', d['uid'])) return false;
      db.raw.execute('INSERT INTO bookmarks(uid,book_id,position,label,pct,at) VALUES(?,?,?,?,?,?)',
          [d['uid'], id, d['position'] ?? '', d['label'] ?? '', _d(d['pct']), d['at'] ?? atSec]);
      return true;
    case 'bookmark_del':
      db.raw.execute('DELETE FROM bookmarks WHERE uid=?', [d['uid']]);
      return true;
    case 'tag_new':
      _tagId(db, d['name'] as String, color: d['color'] as int?);
      return true;
    case 'tag_edit':
      final r = db.raw.select('SELECT id FROM tags WHERE name=?', [d['old']]);
      if (r.isEmpty) return false;
      db.raw.execute('UPDATE tags SET name=?, color=?, sort_index=? WHERE id=?',
          [d['name'], d['color'], d['sort'], r.first['id']]);
      return true;
    case 'tag_del':
      db.raw.execute('DELETE FROM tags WHERE name=?', [d['name']]);
      return true;
    case 'tag_add' || 'tag_remove':
      final name = d['name'] as String?;
      if (name == null) return false;
      final tag = _tagId(db, name);
      for (final u in (d['books'] as List? ?? const [])) {
        final b = _bookId(db, u as String);
        if (b == null) continue;
        if (kind == 'tag_add') {
          final pos = db.raw.select('SELECT COALESCE(MAX(position),0)+1 AS n FROM book_tags WHERE tag_id=?', [tag]).first['n'];
          db.raw.execute('INSERT OR IGNORE INTO book_tags(tag_id,book_id,position) VALUES(?,?,?)', [tag, b, pos]);
        } else {
          db.raw.execute('DELETE FROM book_tags WHERE tag_id=? AND book_id=?', [tag, b]);
        }
      }
      return true;
    default:
      return false; // from a newer app: skipped
  }
}

/// Times read and first/last finished, from the finish records.
void _recount(Db db, int id) {
  final r = db.raw.select('SELECT COUNT(*) AS n, MIN(at) AS a, MAX(at) AS z FROM completions WHERE book_id=?', [id]).first;
  db.raw.execute('UPDATE books SET read_count=?, first_completed_at=?, last_completed_at=? WHERE id=?',
      [r['n'], r['a'] ?? 0, r['z'] ?? 0, id]);
}
