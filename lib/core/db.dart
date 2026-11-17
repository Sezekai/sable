import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'log.dart';
import 'parse.dart';
import 'settings.dart';

const _uuid = Uuid();
String newUid() => _uuid.v4();
int nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
int nowMs() => DateTime.now().millisecondsSinceEpoch;

/// One book file in the library (a book inside a ZIP counts as a file).
class Book {
  int id;
  String uid;
  String path;
  String root;
  String relDir;
  String fileName;
  int size;
  int mtime;
  String fingerprint;
  String format; // epub | pdf | mobi | azw3
  Kind kind;
  bool collection;
  // From inside the file
  String? metaTitle;
  String? metaAuthor;
  String? metaSeries;
  double? metaSeriesIndex;
  String? description;
  String? publisher;
  String? language;
  String? published;
  int textBytes;
  int pages; // PDFs
  // From the file name and folders
  String title;
  String? series;
  double? volume;
  String? subtitle;
  String edition;
  // Hand edits win and survive rescans
  String? userTitle;
  String? userAuthor;
  String? userSeries;
  double? userVolume;
  String? userKind;
  int addedAt;
  bool missing;
  // Reading
  double rating;
  bool favourite;
  String position; // EPUB CFI, or the PDF page number
  double progress; // 0…1
  int lastReadAt;
  int firstCompletedAt;
  int lastCompletedAt;
  int readCount;
  int timeSpent;
  bool manualRead;

  /// Open in the reader on this device right now (not saved).
  bool reading = false;

  Book({
    required this.id,
    required this.uid,
    required this.path,
    required this.root,
    required this.relDir,
    required this.fileName,
    required this.size,
    required this.mtime,
    required this.fingerprint,
    required this.format,
    required this.kind,
    this.collection = false,
    this.metaTitle,
    this.metaAuthor,
    this.metaSeries,
    this.metaSeriesIndex,
    this.description,
    this.publisher,
    this.language,
    this.published,
    this.textBytes = 0,
    this.pages = 0,
    required this.title,
    this.series,
    this.volume,
    this.subtitle,
    this.edition = '',
    this.userTitle,
    this.userAuthor,
    this.userSeries,
    this.userVolume,
    this.userKind,
    required this.addedAt,
    this.missing = false,
    this.rating = 0,
    this.favourite = false,
    this.position = '',
    this.progress = 0,
    this.lastReadAt = 0,
    this.firstCompletedAt = 0,
    this.lastCompletedAt = 0,
    this.readCount = 0,
    this.timeSpent = 0,
    this.manualRead = false,
  });

  Kind get displayKind => userKind == null ? kind : Kind.byName(userKind);
  String? get displayAuthor => userAuthor ?? metaAuthor;

  /// Series: hand edit, else the folder or file name, else the book's own details.
  String? get displaySeries => userSeries ?? series ?? (metaSeries?.isNotEmpty == true ? metaSeries : null);
  double? get displayVolume => userVolume ?? volume ?? (series == null ? metaSeriesIndex : null);
  bool get inSeries => displaySeries != null && (userSeries != null || displayVolume != null || kind == Kind.ln);

  /// The book's name on its own (without the series).
  String get displayTitle {
    if (userTitle != null) return userTitle!;
    if (metaTitle != null && metaTitle!.trim().isNotEmpty && !_junkTitle(metaTitle!)) return metaTitle!.trim();
    return title;
  }

  /// "Vol. 3" etc., or '' when there's no number.
  String get volumeText => displayVolume == null ? '' : 'Vol. ${volumeLabel(displayVolume!)}';

  /// What a card shows as the main line.
  String get cardTitle => inSeries ? (displaySeries ?? displayTitle) : displayTitle;
  String get cardSub => inSeries
      ? [volumeText, if (edition.isNotEmpty) edition].where((x) => x.isNotEmpty).join(' · ')
      : (displayAuthor ?? '');

  String get seriesKey => normKey(displaySeries ?? '');

  /// Same volume in another format (or in a ZIP) shares this key.
  String get volumeKey {
    if (displaySeries != null && displayVolume != null) {
      return 'v|$seriesKey|${normKey(edition)}|${displayVolume!}';
    }
    final a = (displayAuthor ?? '').split(RegExp(r'[,&;]')).first.trim().split(' ').last;
    return 't|${normKey(displayTitle)}|${normKey(a)}';
  }

  bool get isRead => readCount > 0;
  bool get inProgress => readCount == 0 && progress > 0.0;

  /// Length in "pages": 1,500 bytes of text, the same unit the reader counts.
  int get length => format == 'pdf' ? pages : (textBytes / 1500).ceil();

  /// Rough reading time in minutes (the reader uses 1,600 bytes a minute).
  int get minutes => format == 'pdf' ? pages * 2 : (textBytes / 1600).round();

  static bool _junkTitle(String t) {
    final l = t.toLowerCase().trim();
    return l.isEmpty || l == 'unknown' || l == 'untitled' || l.endsWith('.epub') || l.endsWith('.doc') || l.startsWith('microsoft word');
  }

  static Book fromRow(Row r) => Book(
        id: r['id'] as int,
        uid: r['uid'] as String,
        path: r['path'] as String,
        root: r['root'] as String,
        relDir: r['rel_dir'] as String,
        fileName: r['file_name'] as String,
        size: r['size'] as int,
        mtime: r['mtime'] as int,
        fingerprint: r['fingerprint'] as String,
        format: r['format'] as String,
        kind: Kind.byName(r['kind'] as String?),
        collection: (r['collection'] as int? ?? 0) == 1,
        metaTitle: r['meta_title'] as String?,
        metaAuthor: r['meta_author'] as String?,
        metaSeries: r['meta_series'] as String?,
        metaSeriesIndex: (r['meta_series_index'] as num?)?.toDouble(),
        description: r['description'] as String?,
        publisher: r['publisher'] as String?,
        language: r['language'] as String?,
        published: r['published'] as String?,
        textBytes: r['text_bytes'] as int? ?? 0,
        pages: r['pages'] as int? ?? 0,
        title: r['title'] as String,
        series: r['series'] as String?,
        volume: (r['volume'] as num?)?.toDouble(),
        subtitle: r['subtitle'] as String?,
        edition: r['edition'] as String? ?? '',
        userTitle: r['user_title'] as String?,
        userAuthor: r['user_author'] as String?,
        userSeries: r['user_series'] as String?,
        userVolume: (r['user_volume'] as num?)?.toDouble(),
        userKind: r['user_kind'] as String?,
        addedAt: r['added_at'] as int,
        missing: (r['missing'] as int? ?? 0) == 1,
        rating: (r['rating'] as num?)?.toDouble() ?? 0,
        favourite: (r['favourite'] as int? ?? 0) == 1,
        position: r['position'] as String? ?? '',
        progress: (r['progress'] as num?)?.toDouble() ?? 0,
        lastReadAt: r['last_read_at'] as int? ?? 0,
        firstCompletedAt: r['first_completed_at'] as int? ?? 0,
        lastCompletedAt: r['last_completed_at'] as int? ?? 0,
        readCount: r['read_count'] as int? ?? 0,
        timeSpent: r['time_spent'] as int? ?? 0,
        manualRead: (r['manual_read'] as int? ?? 0) == 1,
      );
}

class ReadingSession {
  final int id;
  final int bookId;
  final int startedAt;
  final int endedAt;
  final int activeSeconds;
  final double fromPct;
  final double toPct;
  final int pagesRead;
  final bool completed;
  final String device;
  ReadingSession(this.id, this.bookId, this.startedAt, this.endedAt, this.activeSeconds, this.fromPct, this.toPct,
      this.pagesRead, this.completed, this.device);
}

class Tag {
  int id;
  String name;
  int color;
  int sortIndex;
  Tag(this.id, this.name, this.color, this.sortIndex);
}

class Bookmark {
  final int id;
  final int bookId;
  final String position;
  final String label;
  final double pct;
  final int at;
  Bookmark(this.id, this.bookId, this.position, this.label, this.pct, this.at);
}

/// The library database (SQLite, in the data folder).
class Db {
  Db._(this.raw);
  static late Db I;
  final Database raw;

  /// On the phone, every change to reading records is also written to the
  /// outbox (the `changes` table), which the next sync sends to the PC.
  bool recordChanges = false;

  String? uidOf(int bookId) {
    final r = raw.select('SELECT uid FROM books WHERE id=?', [bookId]);
    return r.isEmpty ? null : r.first['uid'] as String;
  }

  void _op(String kind, int? bookId, Map<String, Object?> payload) {
    if (!recordChanges) return;
    final bu = bookId == null ? null : uidOf(bookId);
    if (bookId != null && bu == null) return;
    raw.execute('INSERT INTO changes(uid,at,kind,book_uid,payload) VALUES(?,?,?,?,?)',
        [newUid(), nowMs(), kind, bu, jsonEncode(payload)]);
  }

  /// The outbox, oldest first.
  List<Map<String, Object?>> outbox() => raw
      .select('SELECT * FROM changes ORDER BY id')
      .map((r) => {
            'id': r['id'],
            'uid': r['uid'],
            'at': r['at'],
            'kind': r['kind'],
            'book': r['book_uid'],
            'data': jsonDecode(r['payload'] as String? ?? '{}'),
          })
      .toList();

  void clearOutbox(int upToId) => raw.execute('DELETE FROM changes WHERE id <= ?', [upToId]);

  static Db open(String path) {
    Directory(p.dirname(path)).createSync(recursive: true);
    final d = sqlite3.open(path);
    d.execute('PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;');
    final db = Db._(d);
    db._migrate();
    return db;
  }

  void _migrate() {
    final v = raw.select('PRAGMA user_version').first.values.first as int;
    if (v < 1) {
      raw.execute('''
CREATE TABLE IF NOT EXISTS books(
  id INTEGER PRIMARY KEY, uid TEXT NOT NULL, path TEXT NOT NULL UNIQUE, root TEXT NOT NULL,
  rel_dir TEXT NOT NULL, file_name TEXT NOT NULL, size INTEGER NOT NULL, mtime INTEGER NOT NULL,
  fingerprint TEXT NOT NULL, format TEXT NOT NULL, kind TEXT NOT NULL, collection INTEGER DEFAULT 0,
  meta_title TEXT, meta_author TEXT, meta_series TEXT, meta_series_index REAL, description TEXT,
  publisher TEXT, language TEXT, published TEXT, text_bytes INTEGER DEFAULT 0, pages INTEGER DEFAULT 0,
  title TEXT NOT NULL, series TEXT, volume REAL, subtitle TEXT, edition TEXT DEFAULT '',
  user_title TEXT, user_author TEXT, user_series TEXT, user_volume REAL, user_kind TEXT,
  added_at INTEGER NOT NULL, missing INTEGER DEFAULT 0,
  rating REAL DEFAULT 0, favourite INTEGER DEFAULT 0, position TEXT DEFAULT '', progress REAL DEFAULT 0,
  last_read_at INTEGER DEFAULT 0, first_completed_at INTEGER DEFAULT 0, last_completed_at INTEGER DEFAULT 0,
  read_count INTEGER DEFAULT 0, time_spent INTEGER DEFAULT 0, manual_read INTEGER DEFAULT 0,
  updated_at INTEGER DEFAULT 0);
CREATE INDEX IF NOT EXISTS books_fp ON books(fingerprint);
CREATE TABLE IF NOT EXISTS sessions(
  id INTEGER PRIMARY KEY, uid TEXT NOT NULL, book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
  started_at INTEGER NOT NULL, ended_at INTEGER NOT NULL, active_seconds INTEGER NOT NULL,
  from_pct REAL, to_pct REAL, pages_read INTEGER DEFAULT 0, completed INTEGER DEFAULT 0,
  device TEXT DEFAULT 'PC', source TEXT DEFAULT 'pc');
CREATE INDEX IF NOT EXISTS sessions_book ON sessions(book_id);
CREATE TABLE IF NOT EXISTS completions(
  id INTEGER PRIMARY KEY, uid TEXT NOT NULL, book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
  at INTEGER NOT NULL, manual INTEGER DEFAULT 0, source TEXT DEFAULT 'pc');
CREATE INDEX IF NOT EXISTS completions_book ON completions(book_id);
CREATE TABLE IF NOT EXISTS tags(
  id INTEGER PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL, sort_index INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS book_tags(
  tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
  position INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(tag_id, book_id));
CREATE TABLE IF NOT EXISTS bookmarks(
  id INTEGER PRIMARY KEY, uid TEXT NOT NULL, book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
  position TEXT NOT NULL, label TEXT NOT NULL, pct REAL DEFAULT 0, at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS changes(
  id INTEGER PRIMARY KEY, uid TEXT NOT NULL, at INTEGER NOT NULL, kind TEXT NOT NULL,
  book_uid TEXT, payload TEXT);
PRAGMA user_version = 1;
''');
    }
  }

  // ---------- books ----------

  List<Book> books() => raw.select('SELECT * FROM books').map(Book.fromRow).toList();

  Book? bookById(int id) {
    final r = raw.select('SELECT * FROM books WHERE id = ?', [id]);
    return r.isEmpty ? null : Book.fromRow(r.first);
  }

  void insertBook(Book b) {
    raw.execute('''INSERT INTO books(uid, path, root, rel_dir, file_name, size, mtime, fingerprint, format, kind,
        collection, meta_title, meta_author, meta_series, meta_series_index, description, publisher, language,
        published, text_bytes, pages, title, series, volume, subtitle, edition, added_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''', [
      b.uid, b.path, b.root, b.relDir, b.fileName, b.size, b.mtime, b.fingerprint, b.format, b.kind.name,
      b.collection ? 1 : 0, b.metaTitle, b.metaAuthor, b.metaSeries, b.metaSeriesIndex, b.description,
      b.publisher, b.language, b.published, b.textBytes, b.pages, b.title, b.series, b.volume, b.subtitle,
      b.edition, b.addedAt,
    ]);
    b.id = raw.lastInsertRowId;
  }

  void updateFile(Book b) {
    raw.execute('''UPDATE books SET path=?, root=?, rel_dir=?, file_name=?, size=?, mtime=?, fingerprint=?,
        format=?, kind=?, collection=?, meta_title=?, meta_author=?, meta_series=?, meta_series_index=?,
        description=?, publisher=?, language=?, published=?, text_bytes=?, pages=?, title=?, series=?, volume=?,
        subtitle=?, edition=?, missing=? WHERE id=?''', [
      b.path, b.root, b.relDir, b.fileName, b.size, b.mtime, b.fingerprint, b.format, b.kind.name,
      b.collection ? 1 : 0, b.metaTitle, b.metaAuthor, b.metaSeries, b.metaSeriesIndex, b.description,
      b.publisher, b.language, b.published, b.textBytes, b.pages, b.title, b.series, b.volume, b.subtitle,
      b.edition, b.missing ? 1 : 0, b.id,
    ]);
  }

  void setMissing(int id, bool missing) =>
      raw.execute('UPDATE books SET missing=? WHERE id=?', [missing ? 1 : 0, id]);

  void updateReading(Book b) {
    _op('state', b.id, {
      'rating': b.rating,
      'favourite': b.favourite,
      'position': b.position,
      'progress': b.progress,
      'last_read_at': b.lastReadAt,
      'manual_read': b.manualRead,
    });
    raw.execute('''UPDATE books SET rating=?, favourite=?, position=?, progress=?, last_read_at=?,
      first_completed_at=?, last_completed_at=?, read_count=?, time_spent=?, manual_read=?, updated_at=?
      WHERE id=?''', [
      b.rating, b.favourite ? 1 : 0, b.position, b.progress, b.lastReadAt, b.firstCompletedAt,
      b.lastCompletedAt, b.readCount, b.timeSpent, b.manualRead ? 1 : 0, nowSec(), b.id,
    ]);
  }

  void updateEdits(Book b) {
    _op('edits', b.id, {
      'user_title': b.userTitle,
      'user_author': b.userAuthor,
      'user_series': b.userSeries,
      'user_volume': b.userVolume,
      'user_kind': b.userKind,
    });
    raw.execute('''UPDATE books SET user_title=?, user_author=?, user_series=?, user_volume=?, user_kind=?,
      updated_at=? WHERE id=?''', [b.userTitle, b.userAuthor, b.userSeries, b.userVolume, b.userKind, nowSec(), b.id]);
  }

  // ---------- reading records ----------

  void addSession({
    required int bookId,
    required int startedAt,
    required int endedAt,
    required int activeSeconds,
    required double fromPct,
    required double toPct,
    required int pagesRead,
    required bool completed,
    String? device,
    String? source,
  }) {
    device ??= recordChanges ? 'Phone' : 'PC';
    source ??= recordChanges ? 'phone' : 'pc';
    final uid = newUid();
    _op('session', bookId, {
      'uid': uid,
      'started_at': startedAt,
      'ended_at': endedAt,
      'active_seconds': activeSeconds,
      'from_pct': fromPct,
      'to_pct': toPct,
      'pages_read': pagesRead,
      'completed': completed,
      'device': device,
    });
    raw.execute(
        '''INSERT INTO sessions(uid,book_id,started_at,ended_at,active_seconds,from_pct,to_pct,pages_read,
        completed,device,source) VALUES(?,?,?,?,?,?,?,?,?,?,?)''',
        [uid, bookId, startedAt, endedAt, activeSeconds, fromPct, toPct, pagesRead, completed ? 1 : 0, device, source]);
  }

  void addCompletion(int bookId, int at, {bool manual = false, String? source}) {
    source ??= recordChanges ? 'phone' : 'pc';
    final uid = newUid();
    _op('completion', bookId, {'uid': uid, 'at': at, 'manual': manual});
    raw.execute('INSERT INTO completions(uid,book_id,at,manual,source) VALUES(?,?,?,?,?)',
        [uid, bookId, at, manual ? 1 : 0, source]);
  }

  void removeManualCompletions(int bookId) {
    _op('uncomplete', bookId, {});
    raw.execute('DELETE FROM completions WHERE book_id=? AND manual=1', [bookId]);
  }

  List<ReadingSession> sessions({int? bookId, int? since}) {
    final where = <String>[];
    final args = <Object?>[];
    if (bookId != null) {
      where.add('book_id = ?');
      args.add(bookId);
    }
    if (since != null) {
      where.add('started_at >= ?');
      args.add(since);
    }
    return raw
        .select('SELECT * FROM sessions${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'} ORDER BY started_at DESC', args)
        .map((r) => ReadingSession(
            r['id'] as int,
            r['book_id'] as int,
            r['started_at'] as int,
            r['ended_at'] as int,
            r['active_seconds'] as int,
            (r['from_pct'] as num?)?.toDouble() ?? 0,
            (r['to_pct'] as num?)?.toDouble() ?? 0,
            r['pages_read'] as int? ?? 0,
            (r['completed'] as int? ?? 0) == 1,
            r['device'] as String? ?? 'PC'))
        .toList();
  }

  List<(int bookId, int at, bool manual)> completions({int? bookId}) => raw
      .select('SELECT * FROM completions${bookId == null ? '' : ' WHERE book_id = ?'} ORDER BY at DESC',
          [?bookId])
      .map((r) => (r['book_id'] as int, r['at'] as int, (r['manual'] as int? ?? 0) == 1))
      .toList();

  void deleteSession(int id) {
    final r = raw.select('SELECT uid, book_id FROM sessions WHERE id=?', [id]);
    if (r.isNotEmpty) _op('session_del', r.first['book_id'] as int, {'uid': r.first['uid']});
    raw.execute('DELETE FROM sessions WHERE id=?', [id]);
  }

  // ---------- tags ----------

  List<Tag> tags() => raw
      .select('SELECT * FROM tags ORDER BY sort_index, name')
      .map((r) => Tag(r['id'] as int, r['name'] as String, r['color'] as int, r['sort_index'] as int))
      .toList();

  Tag createTag(String name, int color) {
    final idx = raw.select('SELECT COALESCE(MAX(sort_index),0)+1 AS n FROM tags').first['n'] as int;
    _op('tag_new', null, {'name': name, 'color': color});
    raw.execute('INSERT INTO tags(name,color,sort_index) VALUES(?,?,?)', [name, color, idx]);
    return Tag(raw.lastInsertRowId, name, color, idx);
  }

  String? _tagName(int id) {
    final r = raw.select('SELECT name FROM tags WHERE id=?', [id]);
    return r.isEmpty ? null : r.first['name'] as String;
  }

  void updateTag(Tag t) {
    final old = _tagName(t.id);
    if (old != null) _op('tag_edit', null, {'old': old, 'name': t.name, 'color': t.color, 'sort': t.sortIndex});
    raw.execute('UPDATE tags SET name=?, color=?, sort_index=? WHERE id=?', [t.name, t.color, t.sortIndex, t.id]);
  }

  void deleteTag(int id) {
    final old = _tagName(id);
    if (old != null) _op('tag_del', null, {'name': old});
    raw.execute('DELETE FROM tags WHERE id=?', [id]);
  }

  /// book id -> tag ids
  Map<int, Set<int>> tagMap() {
    final m = <int, Set<int>>{};
    for (final r in raw.select('SELECT book_id, tag_id FROM book_tags')) {
      m.putIfAbsent(r['book_id'] as int, () => {}).add(r['tag_id'] as int);
    }
    return m;
  }

  void addToTag(int tagId, Iterable<int> bookIds) {
    if (recordChanges) {
      _op('tag_add', null, {'name': _tagName(tagId), 'books': [for (final id in bookIds) ?uidOf(id)]});
    }
    var pos = raw.select('SELECT COALESCE(MAX(position),0) AS n FROM book_tags WHERE tag_id=?', [tagId]).first['n'] as int;
    final st = raw.prepare('INSERT OR IGNORE INTO book_tags(tag_id,book_id,position) VALUES(?,?,?)');
    for (final id in bookIds) {
      st.execute([tagId, id, ++pos]);
    }
    st.close();
  }

  void removeFromTag(int tagId, Iterable<int> bookIds) {
    if (recordChanges) {
      _op('tag_remove', null, {'name': _tagName(tagId), 'books': [for (final id in bookIds) ?uidOf(id)]});
    }
    for (final id in bookIds) {
      raw.execute('DELETE FROM book_tags WHERE tag_id=? AND book_id=?', [tagId, id]);
    }
  }

  // ---------- bookmarks ----------

  List<Bookmark> bookmarks(int bookId) => raw
      .select('SELECT * FROM bookmarks WHERE book_id=? ORDER BY pct', [bookId])
      .map((r) => Bookmark(r['id'] as int, r['book_id'] as int, r['position'] as String, r['label'] as String,
          (r['pct'] as num?)?.toDouble() ?? 0, r['at'] as int))
      .toList();

  void addBookmark(int bookId, String position, String label, double pct) {
    final uid = newUid(), at = nowSec();
    _op('bookmark_add', bookId, {'uid': uid, 'position': position, 'label': label, 'pct': pct, 'at': at});
    raw.execute('INSERT INTO bookmarks(uid,book_id,position,label,pct,at) VALUES(?,?,?,?,?,?)',
        [uid, bookId, position, label, pct, at]);
  }

  void deleteBookmark(int id) {
    final r = raw.select('SELECT uid, book_id FROM bookmarks WHERE id=?', [id]);
    if (r.isNotEmpty) _op('bookmark_del', r.first['book_id'] as int, {'uid': r.first['uid']});
    raw.execute('DELETE FROM bookmarks WHERE id=?', [id]);
  }

  // ---------- maintenance ----------

  /// Keeps the last 7 daily copies of the database, since it holds all history.
  void backup(String dir) {
    try {
      Directory(dir).createSync(recursive: true);
      final stamp = DateTime.now().toIso8601String().substring(0, 10);
      final target = p.join(dir, 'library-$stamp.db');
      if (File(target).existsSync()) return;
      raw.execute("VACUUM INTO '${target.replaceAll("'", "''")}'");
      final files = Directory(dir)
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('library-'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final f in files.skip(7)) {
        f.deleteSync();
      }
    } catch (e) {
      AppLog.I.warn('Couldn\'t back up the library database: $e');
    }
  }

  void resetLibrary() => raw.execute(
      'DELETE FROM book_tags; DELETE FROM bookmarks; DELETE FROM sessions; DELETE FROM completions; DELETE FROM books;');

  void resetHistory() => raw.execute('DELETE FROM sessions; DELETE FROM completions; '
      "UPDATE books SET position='', progress=0, last_read_at=0, first_completed_at=0, last_completed_at=0, "
      'read_count=0, time_spent=0, manual_read=0;');

  void close() => raw.close();
}
