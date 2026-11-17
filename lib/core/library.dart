import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'books.dart';
import 'db.dart';
import 'jobs.dart';
import 'log.dart';
import 'parse.dart';
import 'paths.dart';
import 'settings.dart';

enum Tri { any, yes, no }

Tri nextTri(Tri t) => Tri.values[(t.index + 1) % 3];

/// Library filters. Every filter has its opposite (Tri.no), and they combine.
class LibFilter {
  String search = '';
  Tri read = Tri.any;
  Tri inProgress = Tri.any;
  Tri favourite = Tri.any;
  Tri rated = Tri.any;
  Tri series = Tri.any;
  Tri ln = Tri.any; // yes = light novels only, no = books only
  Tri pdf = Tri.any;
  Set<String> authors = {};
  Set<String> excludeAuthors = {};
  Set<int> tags = {};
  Set<int> excludeTags = {};
  Tri ratingRange = Tri.any;
  double minRating = 0.5;
  double maxRating = 5;
  Tri readCount = Tri.any;
  int readCountMin = 2;
  Tri lengthRange = Tri.any;
  int minLength = 0;
  int maxLength = 300;
  Tri readIn = Tri.any;
  int readInDays = 30;

  bool get isEmpty =>
      search.isEmpty &&
      read == Tri.any &&
      inProgress == Tri.any &&
      favourite == Tri.any &&
      rated == Tri.any &&
      series == Tri.any &&
      ln == Tri.any &&
      pdf == Tri.any &&
      authors.isEmpty &&
      excludeAuthors.isEmpty &&
      tags.isEmpty &&
      excludeTags.isEmpty &&
      ratingRange == Tri.any &&
      readCount == Tri.any &&
      lengthRange == Tri.any &&
      readIn == Tri.any;

  Map<String, dynamic> toJson() => {
        'search': search,
        'read': read.index,
        'inProgress': inProgress.index,
        'favourite': favourite.index,
        'rated': rated.index,
        'series': series.index,
        'ln': ln.index,
        'pdf': pdf.index,
        'authors': authors.toList(),
        'excludeAuthors': excludeAuthors.toList(),
        'tags': tags.toList(),
        'excludeTags': excludeTags.toList(),
        'ratingRange': ratingRange.index,
        'minRating': minRating,
        'maxRating': maxRating,
        'readCount': readCount.index,
        'readCountMin': readCountMin,
        'lengthRange': lengthRange.index,
        'minLength': minLength,
        'maxLength': maxLength,
        'readIn': readIn.index,
        'readInDays': readInDays,
      };

  static LibFilter fromJson(Map m) {
    Tri t(String k) => Tri.values[((m[k] as int?) ?? 0).clamp(0, 2)];
    return LibFilter()
      ..search = m['search'] as String? ?? ''
      ..read = t('read')
      ..inProgress = t('inProgress')
      ..favourite = t('favourite')
      ..rated = t('rated')
      ..series = t('series')
      ..ln = t('ln')
      ..pdf = t('pdf')
      ..authors = ((m['authors'] as List?) ?? []).cast<String>().toSet()
      ..excludeAuthors = ((m['excludeAuthors'] as List?) ?? []).cast<String>().toSet()
      ..tags = ((m['tags'] as List?) ?? []).cast<int>().toSet()
      ..excludeTags = ((m['excludeTags'] as List?) ?? []).cast<int>().toSet()
      ..ratingRange = t('ratingRange')
      ..minRating = (m['minRating'] as num?)?.toDouble() ?? 0.5
      ..maxRating = (m['maxRating'] as num?)?.toDouble() ?? 5
      ..readCount = t('readCount')
      ..readCountMin = m['readCountMin'] as int? ?? 2
      ..lengthRange = t('lengthRange')
      ..minLength = m['minLength'] as int? ?? 0
      ..maxLength = m['maxLength'] as int? ?? 300
      ..readIn = t('readIn')
      ..readInDays = m['readInDays'] as int? ?? 30;
  }

  LibFilter copy() => fromJson(toJson());
}

const sortKeys = {
  'title': 'Title A–Z',
  'author': 'Author',
  'series': 'Series',
  'added': 'Date added',
  'lastRead': 'Last read',
  'lastCompleted': 'Last finished',
  'firstCompleted': 'First finished',
  'progress': 'Progress',
  'rating': 'Rating',
  'length': 'Length',
  'readCount': 'Times read',
  'timeSpent': 'Time spent reading',
  'random': 'Random',
};

const _formatRank = {'epub': 0, 'azw3': 1, 'mobi': 2, 'pdf': 3};

/// One volume: the same book, possibly in several formats or copies.
class Volume {
  Volume(this.key, List<Book> files) : files = _ordered(files);
  final String key;
  final List<Book> files;

  static List<Book> _ordered(List<Book> fs) {
    final l = [...fs];
    l.sort((a, b) {
      final za = isInZip(a.path) ? 1 : 0, zb = isInZip(b.path) ? 1 : 0;
      final c = (_formatRank[a.format] ?? 9).compareTo(_formatRank[b.format] ?? 9);
      return c != 0 ? c : za.compareTo(zb);
    });
    return l;
  }

  /// The file Read opens: the one read last, else the best format.
  Book get primary {
    Book? last;
    for (final f in files) {
      if (f.lastReadAt > 0 && (last == null || f.lastReadAt > last.lastReadAt)) last = f;
    }
    return last ?? files.first;
  }

  /// One copy per format, preferring files not in a ZIP.
  List<Book> get formats {
    final seen = <String>{};
    return [
      for (final f in files)
        if (seen.add(f.format)) f
    ];
  }

  Book get any => primary;
  bool get isRead => files.any((f) => f.isRead);
  bool get inProgress => !isRead && primary.progress > 0;
  double get progress => isRead && primary.progress == 0 ? 1 : primary.progress;
  bool get favourite => files.any((f) => f.favourite);
  double get rating => files.map((f) => f.rating).reduce(max);
  int get lastReadAt => files.map((f) => f.lastReadAt).reduce(max);
  int get lastCompletedAt => files.map((f) => f.lastCompletedAt).reduce(max);
  int get firstCompletedAt {
    final xs = files.map((f) => f.firstCompletedAt).where((x) => x > 0);
    return xs.isEmpty ? 0 : xs.reduce(min);
  }

  int get readCount => files.map((f) => f.readCount).reduce(max);
  int get timeSpent => files.fold(0, (a, f) => a + f.timeSpent);
  int get addedAt => files.map((f) => f.addedAt).reduce(min);
  int get length => files.first.length;
}

/// What the grid shows: a single volume or a whole series.
sealed class Entry {
  String get name;
  List<Volume> get volumes;
  Volume get cover => volumes.first;
}

class VolumeEntry extends Entry {
  VolumeEntry(this.v);
  final Volume v;
  @override
  String get name => v.any.cardTitle;
  @override
  List<Volume> get volumes => [v];
}

class SeriesEntry extends Entry {
  SeriesEntry(this.key, this.label, this.volumes);
  final String key;
  final String label;
  @override
  final List<Volume> volumes; // in reading order
  @override
  String get name => label;
  int get readCount => volumes.where((v) => v.isRead).length;
  List<String> get editions {
    final e = volumes.map((v) => v.any.edition).toSet().toList()..sort();
    return e;
  }

  /// The volume to continue with: the one in progress, else the first unread.
  Volume get next {
    final inProg = volumes.where((v) => v.inProgress).toList()..sort((a, b) => b.lastReadAt.compareTo(a.lastReadAt));
    if (inProg.isNotEmpty) return inProg.first;
    return volumes.firstWhere((v) => !v.isRead, orElse: () => volumes.first);
  }
}

typedef PdfInspector = Future<(int pages, Uint8List? cover)> Function(String path);

/// The library: every book in memory, with the database kept in step.
class Library extends ChangeNotifier {
  Library._();
  static final Library I = Library._();

  final List<Book> _books = [];
  final Map<int, Book> _byId = {};
  List<Tag> _tags = [];
  Map<int, Set<int>> _tagMap = {};
  final Set<String> unavailableRoots = {};
  LibFilter filter = LibFilter();
  int _seed = Random().nextInt(1 << 30);
  final List<StreamSubscription> _watchers = [];
  Timer? _watchDebounce;
  PdfInspector? pdfInspector;

  /// Passwords for locked ZIPs: from Settings and from password .txt files.
  List<String> zipPasswords = [];

  // Cached grouping, rebuilt when the library changes.
  Map<String, Volume>? _volumes;
  Map<String, List<Volume>>? _series;

  List<Book> get books => _books;
  List<Tag> get tags => _tags;
  Book? byId(int id) => _byId[id];
  Set<int> tagsOf(Book b) => _tagMap[b.id] ?? const {};
  Set<int> tagsOfVolume(Volume v) => {for (final f in v.files) ...tagsOf(f)};
  Tag? tagById(int id) => _tags.where((t) => t.id == id).firstOrNull;

  void load() {
    _books
      ..clear()
      ..addAll(Db.I.books());
    _byId
      ..clear()
      ..addEntries(_books.map((b) => MapEntry(b.id, b)));
    _tags = Db.I.tags();
    _tagMap = Db.I.tagMap();
    changed();
  }

  void reloadTags() {
    _tags = Db.I.tags();
    _tagMap = Db.I.tagMap();
    changed();
  }

  void changed() {
    _volumes = null;
    _series = null;
    notifyListeners();
  }

  void reshuffle() {
    _seed = Random().nextInt(1 << 30);
    notifyListeners();
  }

  bool visible(Book b) => !b.missing && (Settings.I.showCollections || !b.collection);

  // ---------------- grouping ----------------

  Map<String, Volume> get volumes {
    if (_volumes != null) return _volumes!;
    final m = <String, List<Book>>{};
    for (final b in _books) {
      if (!visible(b)) continue;
      m.putIfAbsent(b.volumeKey, () => []).add(b);
    }
    return _volumes = {for (final e in m.entries) e.key: Volume(e.key, e.value)};
  }

  /// Series key -> volumes in order, for series with two or more volumes.
  Map<String, List<Volume>> get series {
    if (_series != null) return _series!;
    final m = <String, List<Volume>>{};
    for (final v in volumes.values) {
      final b = v.any;
      if (!b.inSeries) continue;
      m.putIfAbsent(b.seriesKey, () => []).add(v);
    }
    m.removeWhere((k, v) => v.length < 2);
    for (final l in m.values) {
      l.sort(volumeOrder);
    }
    return _series = m;
  }

  static int volumeOrder(Volume a, Volume b) {
    final ea = a.any.edition, eb = b.any.edition;
    if (ea != eb) return ea.isEmpty ? -1 : (eb.isEmpty ? 1 : ea.compareTo(eb));
    final va = a.any.displayVolume ?? 9999, vb = b.any.displayVolume ?? 9999;
    final c = va.compareTo(vb);
    return c != 0 ? c : naturalCompare(a.any.fileName, b.any.fileName);
  }

  Volume? volumeOf(Book b) => volumes[b.volumeKey];
  List<Volume>? seriesOf(Book b) => series[b.seriesKey];

  // ---------------- queries ----------------

  bool matches(Volume v, LibFilter f, {bool inSeries = false}) {
    final b = v.any;
    if (f.search.isNotEmpty) {
      final tagNames = tagsOfVolume(v).map((id) => tagById(id)?.name ?? '').join(' ');
      final hay = '${b.displayTitle} ${b.displaySeries ?? ''} ${b.displayAuthor ?? ''} ${b.edition} '
              '${v.files.map((x) => x.fileName).join(' ')} $tagNames'
          .toLowerCase();
      for (final word in f.search.toLowerCase().split(RegExp(r'\s+'))) {
        if (word.isNotEmpty && !hay.contains(word)) return false;
      }
    }
    bool tri(Tri x, bool val) => x == Tri.any || (x == Tri.yes ? val : !val);
    if (!tri(f.read, v.isRead)) return false;
    if (!tri(f.inProgress, v.inProgress)) return false;
    if (!tri(f.favourite, v.favourite)) return false;
    if (!tri(f.rated, v.rating > 0)) return false;
    if (!tri(f.series, inSeries)) return false;
    if (!tri(f.ln, b.displayKind == Kind.ln)) return false;
    if (!tri(f.pdf, v.files.every((x) => x.format == 'pdf'))) return false;
    final a = b.displayAuthor ?? '';
    if (f.authors.isNotEmpty && !f.authors.contains(a)) return false;
    if (f.excludeAuthors.contains(a)) return false;
    final tg = tagsOfVolume(v);
    if (f.tags.isNotEmpty && !f.tags.every(tg.contains)) return false;
    if (f.excludeTags.any(tg.contains)) return false;
    final r = v.rating;
    if (!tri(f.ratingRange, r > 0 && r >= f.minRating && r <= f.maxRating)) return false;
    if (!tri(f.readCount, v.readCount >= f.readCountMin)) return false;
    final len = v.length;
    if (!tri(f.lengthRange, len >= f.minLength && len <= f.maxLength)) return false;
    if (!tri(f.readIn, v.lastReadAt >= nowSec() - f.readInDays * 86400)) return false;
    return true;
  }

  /// The grid's entries after filters, grouping and sorting.
  List<Entry> entries() {
    final f = filter;
    final out = <Entry>[];
    final grouped = <String>{};
    for (final e in series.entries) {
      if (e.value.any((v) => matches(v, f, inSeries: true))) {
        out.add(SeriesEntry(e.key, e.value.first.any.displaySeries ?? '', e.value));
      }
      for (final v in e.value) {
        grouped.add(v.key);
      }
    }
    for (final v in volumes.values) {
      if (grouped.contains(v.key)) continue;
      if (matches(v, f)) out.add(VolumeEntry(v));
    }
    sortEntries(out, Settings.I.sort, Settings.I.sortDesc);
    return out;
  }

  /// Books being read, most recent first.
  List<Volume> continueReading() {
    final l = volumes.values.where((v) => v.inProgress).toList()..sort((a, b) => b.lastReadAt.compareTo(a.lastReadAt));
    return l.take(20).toList();
  }

  void sortEntries(List<Entry> list, String key, bool desc) {
    num agg(Entry e, num Function(Volume) f, {bool useMax = true, bool sum = false}) {
      final vs = e.volumes;
      if (sum) return vs.fold<num>(0, (a, v) => a + f(v));
      return vs.map(f).reduce((a, b) => useMax ? (a > b ? a : b) : (a < b ? a : b));
    }

    int cmp(Entry a, Entry b) {
      switch (key) {
        case 'author':
          final c = (a.cover.any.displayAuthor ?? '￿').toLowerCase().compareTo((b.cover.any.displayAuthor ?? '￿').toLowerCase());
          return c != 0 ? c : naturalCompare(a.name, b.name);
        case 'series':
          final sa = a is SeriesEntry ? a.label : (a.cover.any.displaySeries ?? a.name);
          final sb = b is SeriesEntry ? b.label : (b.cover.any.displaySeries ?? b.name);
          return naturalCompare(sa, sb);
        case 'added':
          return agg(a, (v) => v.addedAt).compareTo(agg(b, (v) => v.addedAt));
        case 'lastRead':
          return agg(a, (v) => v.lastReadAt).compareTo(agg(b, (v) => v.lastReadAt));
        case 'lastCompleted':
          return agg(a, (v) => v.lastCompletedAt).compareTo(agg(b, (v) => v.lastCompletedAt));
        case 'firstCompleted':
          int fc(Volume v) => v.firstCompletedAt == 0 ? 1 << 40 : v.firstCompletedAt;
          return agg(a, fc, useMax: false).compareTo(agg(b, fc, useMax: false));
        case 'progress':
          return entryProgress(a).compareTo(entryProgress(b));
        case 'rating':
          return agg(a, (v) => v.rating).compareTo(agg(b, (v) => v.rating));
        case 'length':
          return agg(a, (v) => v.length, sum: true).compareTo(agg(b, (v) => v.length, sum: true));
        case 'readCount':
          return agg(a, (v) => v.readCount, sum: true).compareTo(agg(b, (v) => v.readCount, sum: true));
        case 'timeSpent':
          return agg(a, (v) => v.timeSpent, sum: true).compareTo(agg(b, (v) => v.timeSpent, sum: true));
        case 'random':
          int h(Entry e) => (e.cover.any.id * 2654435761 ^ _seed).toUnsigned(32);
          return h(a).compareTo(h(b));
        default:
          return naturalCompare(a.name, b.name);
      }
    }

    list.sort((a, b) {
      final c = cmp(a, b);
      final r = desc ? -c : c;
      return r != 0 ? r : naturalCompare(a.name, b.name);
    });
  }

  double entryProgress(Entry e) {
    if (e is VolumeEntry) return e.v.progress;
    final vs = e.volumes;
    return vs.where((v) => v.isRead).length / vs.length;
  }

  /// Authors with how many volumes each.
  Map<String, int> authorCounts() {
    final m = <String, int>{};
    for (final v in volumes.values) {
      final a = v.any.displayAuthor;
      if (a == null || a.isEmpty) continue;
      m[a] = (m[a] ?? 0) + 1;
    }
    return m;
  }

  // ---------------- reading state ----------------

  void setRating(Volume v, double r) {
    for (final f in v.files) {
      f.rating = r;
      Db.I.updateReading(f);
    }
    changed();
  }

  void toggleFavourite(Iterable<Volume> vs, [bool? value]) {
    final val = value ?? !vs.every((v) => v.favourite);
    for (final v in vs) {
      for (final f in v.files) {
        f.favourite = val;
        Db.I.updateReading(f);
      }
    }
    changed();
  }

  /// Marks read by hand. Hand marks don't count towards reading time.
  void markRead(Iterable<Volume> vs, bool read) {
    final now = nowSec();
    Db.I.raw.execute('BEGIN');
    for (final v in vs) {
      if (read) {
        if (v.isRead) continue;
        final b = v.primary;
        Db.I.addCompletion(b.id, now, manual: true);
        b
          ..readCount = 1
          ..manualRead = true
          ..firstCompletedAt = b.firstCompletedAt == 0 ? now : b.firstCompletedAt
          ..lastCompletedAt = now
          ..progress = 1;
        Db.I.updateReading(b);
      } else {
        for (final b in v.files) {
          Db.I.removeManualCompletions(b.id);
          final left = Db.I.completions(bookId: b.id);
          b
            ..readCount = left.length
            ..manualRead = false;
          if (left.isEmpty) {
            b
              ..firstCompletedAt = 0
              ..lastCompletedAt = 0
              ..progress = 0
              ..position = '';
          }
          Db.I.updateReading(b);
        }
      }
    }
    Db.I.raw.execute('COMMIT');
    changed();
  }

  /// Every volume before [v] in its series (same edition).
  List<Volume> previousVolumes(Volume v) {
    final s = seriesOf(v.any);
    if (s == null) return [];
    final i = s.indexWhere((x) => x.key == v.key);
    return i <= 0 ? [] : s.sublist(0, i).where((x) => x.any.edition == v.any.edition).toList();
  }

  /// The next volume to read after [v], or null at the end of a series.
  Volume? nextVolume(Volume v, {bool skipRead = false}) {
    final s = seriesOf(v.any);
    if (s == null) return null;
    final same = s.where((x) => x.any.edition == v.any.edition).toList();
    final i = same.indexWhere((x) => x.key == v.key);
    for (var j = i + 1; j < same.length; j++) {
      if (!skipRead || !same[j].isRead) return same[j];
    }
    return null;
  }

  void saveEdits(Book b) {
    Db.I.updateEdits(b);
    changed();
  }

  // ---------------- tags ----------------

  static const tagColors = [0xff9b86ff, 0xff2fe0c0, 0xffff6fb1, 0xffffbf5a, 0xff5aa8ff, 0xff5be38a, 0xffff8a5c,
    0xffd07bff, 0xff7fd4ff, 0xfff2e05a];

  Tag createTag(String name) {
    final t = Db.I.createTag(name, tagColors[_tags.length % tagColors.length]);
    reloadTags();
    return t;
  }

  void addTag(Tag tag, Iterable<Volume> vs) {
    Db.I.addToTag(tag.id, vs.expand((v) => v.files).map((b) => b.id));
    reloadTags();
  }

  void removeTag(Tag tag, Iterable<Volume> vs) {
    Db.I.removeFromTag(tag.id, vs.expand((v) => v.files).map((b) => b.id));
    reloadTags();
  }

  // ---------------- scanning ----------------

  static const scanName = 'Scanning the library';

  void scan() {
    if (Jobs.I.isQueued(scanName)) return;
    Jobs.I.add(Job(scanName, _scan, canPause: true));
  }

  Future<String?> _scan(Job job) async {
    final folders = Settings.I.folders;
    unavailableRoots.clear();
    job.setDetail('Listing files…');
    final listed = <String, (int, int, LibFolder)>{}; // path -> size, mtime, folder
    final zips = <String, (int, int, LibFolder)>{};
    for (final lf in folders) {
      if (!Directory(lf.path).existsSync()) {
        unavailableRoots.add(lf.path);
        AppLog.I.warn('The folder ${lf.path} can\'t be reached. Is its drive connected?');
        continue;
      }
      final root = lf.path;
      final files = await listFilesInIsolate(root);
      for (final f in files) {
        (f.$1.toLowerCase().endsWith('.zip') ? zips : listed)[f.$1] = (f.$2, f.$3, lf);
      }
      if (!await job.checkpoint()) return null;
    }

    // Books inside ZIPs. A ZIP that hasn't changed keeps its known books.
    final known = {for (final b in _books) b.path: b};
    final knownZip = <String, List<Book>>{};
    for (final b in _books) {
      if (isInZip(b.path)) knownZip.putIfAbsent(outerPath(b.path), () => []).add(b);
    }
    final zipsToList = <String>[];
    for (final z in zips.entries) {
      final had = knownZip[z.key];
      if (had != null && had.isNotEmpty && had.every((b) => b.mtime == z.value.$2)) {
        for (final b in had) {
          listed[b.path] = (b.size, b.mtime, z.value.$3);
        }
      } else {
        zipsToList.add(z.key);
      }
    }
    if (zipsToList.isNotEmpty) {
      job.setDetail('Looking inside ${zipsToList.length} ZIPs…');
      final found = await listZipsInIsolate(zipsToList);
      for (final (z, entries) in found) {
        for (final (name, size) in entries) {
          listed['$z$zipSep$name'] = (size, zips[z]!.$2, zips[z]!.$3);
        }
      }
    }
    notifyListeners();

    final toInspect = <String>[];
    for (final e in listed.entries) {
      final b = known[e.key];
      final changedSize = b != null && !isInZip(b.path) && b.size != e.value.$1;
      if (b == null || changedSize || b.mtime != e.value.$2) {
        toInspect.add(e.key);
      } else {
        // Folder settings may have changed (kind, collection) without the file changing.
        final lf = e.value.$3;
        if (b.missing || b.root != lf.path || b.collection != lf.collection) {
          _applyFolder(b, lf);
          b.missing = false;
          Db.I.updateFile(b);
        }
      }
    }
    // Missing files: only under folders that can be reached.
    final goneByFp = <String, Book>{};
    for (final b in _books) {
      if (listed.containsKey(b.path)) continue;
      if (unavailableRoots.any((r) => p.isWithin(r, outerPath(b.path)))) continue;
      if (!b.missing) {
        b.missing = true;
        Db.I.setMissing(b.id, true);
      }
      goneByFp[b.fingerprint] = b;
    }

    final total = toInspect.length;
    var done = 0, added = 0, moved = 0, updated = 0, failed = 0;
    job.progress(0, total: total, detail: total == 0 ? 'Nothing new' : 'Reading new and changed books');
    // Books are read on several cores at once.
    final roots = Settings.I.folders.map((f) => f.path).toList();
    zipPasswords = [...Settings.I.zipPasswords, ...await passwordsInIsolate(roots)];
    final workers = max(2, min(6, Platform.numberOfProcessors - 1));
    const per = 8;
    final batchSize = per * workers;
    for (var i = 0; i < toInspect.length; i += batchSize) {
      if (!await job.checkpoint()) break;
      final batch = toInspect.sublist(i, min(i + batchSize, toInspect.length));
      final parts = [for (var j = 0; j < batch.length; j += per) batch.sublist(j, min(j + per, batch.length))];
      final infos = (await Future.wait(parts.map((x) => inspectInIsolate(x, zipPasswords)))).expand((x) => x).toList();
      for (final info in infos) {
        if (info.format == 'pdf' && info.error == null) await _inspectPdf(info);
      }
      Db.I.raw.execute('BEGIN');
      for (final info in infos) {
        final lf = listed[info.path]!.$3;
        if (info.error != null) {
          failed++;
          AppLog.I.warn('Couldn\'t read ${p.basename(info.path)}: ${info.error}');
          if (info.fingerprint.isEmpty) {
            done++;
            continue;
          }
        }
        if (info.cover != null) await _saveCover(info.fingerprint, info.cover!);
        final ex = known[info.path];
        if (ex != null) {
          _apply(ex, info, lf);
          Db.I.updateFile(ex);
          updated++;
        } else if (goneByFp[info.fingerprint] != null) {
          final b = goneByFp.remove(info.fingerprint)!;
          known.remove(b.path);
          _apply(b, info, lf);
          Db.I.updateFile(b);
          moved++;
        } else {
          final b = _newBook(info, lf);
          try {
            Db.I.insertBook(b);
            _books.add(b);
            _byId[b.id] = b;
            added++;
          } catch (e) {
            AppLog.I.warn('Couldn\'t add ${b.fileName}: $e');
          }
        }
        done++;
      }
      Db.I.raw.execute('COMMIT');
      job.progress(done, detail: p.basename(batch.last));
      if ((i ~/ batchSize) % 4 == 3) changed();
    }
    changed();
    Covers.I.queueMissing();
    final missing = _books.where((b) => b.missing).length;
    return 'Library: ${listed.length} books · $added new · $moved moved · $updated updated'
        '${failed > 0 ? ' · $failed couldn\'t be read' : ''}${missing > 0 ? ' · $missing not found' : ''}';
  }

  static List<(String, int, int)> listFiles(String root) {
    final out = <(String, int, int)>[];
    void walk(Directory d) {
      List<FileSystemEntity> items;
      try {
        items = d.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      for (final e in items) {
        final name = p.basename(e.path);
        if (e is Directory) {
          if (name.startsWith('.')) continue;
          walk(e);
        } else if (e is File) {
          final ext = p.extension(name).toLowerCase();
          if (bookExtensions.contains(ext) || ext == '.zip') {
            try {
              final st = e.statSync();
              out.add((e.path, st.size, st.modified.millisecondsSinceEpoch ~/ 1000));
            } catch (_) {}
          }
        }
      }
    }

    walk(Directory(root));
    return out;
  }

  Future<void> _inspectPdf(BookInfo info) async {
    final insp = pdfInspector;
    if (insp == null) return;
    try {
      final path = isInZip(info.path) ? await extractFromZip(info.path) : info.path;
      final (pages, cover) = await insp(path);
      info.pages = pages;
      info.cover = cover;
    } catch (e) {
      AppLog.I.warn('Couldn\'t open the PDF ${p.basename(info.path)}: $e');
    }
  }

  /// Copies a book out of its ZIP into the cache, so the reader can open it.
  /// The ZIP itself isn't changed.
  Future<String> extractFromZip(String path) async {
    final ext = p.extension(innerName(path));
    final name = '${pathKey(path)}$ext';
    final out = File(p.join(AppPaths.I.bookCache, name));
    if (await out.exists()) return out.path;
    final zip = outerPath(path), inner = innerName(path);
    final bytes = await readZipInIsolate(zip, inner, zipPasswords);
    if (bytes == null) throw 'the book isn\'t in the ZIP any more';
    await writeFileSafely(out.path, bytes);
    return out.path;
  }

  static String pathKey(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  void _applyFolder(Book b, LibFolder lf) {
    b
      ..root = lf.path
      ..kind = lf.kind
      ..collection = lf.collection;
    final outer = outerPath(b.path);
    final rel = p.relative(p.dirname(outer), from: lf.path);
    b.relDir = rel == '.' ? '' : rel;
    final parsed = parseBookName(isInZip(b.path) ? p.basename(innerName(b.path)) : b.fileName,
        relDir: b.relDir, seriesFromFolder: lf.kind == Kind.ln);
    b
      ..title = parsed.title
      ..series = parsed.series
      ..volume = parsed.volume
      ..subtitle = parsed.subtitle
      ..edition = parsed.edition;
    // A ZIP named after its volume ("86 - LN 01.zip") fills in a missing number.
    if (b.volume == null && isInZip(b.path)) {
      final z = parseBookName(p.basename(outer), relDir: b.relDir, seriesFromFolder: lf.kind == Kind.ln);
      b.volume = z.volume;
    }
  }

  void _apply(Book b, BookInfo info, LibFolder lf) {
    b
      ..path = info.path
      ..fileName = p.basename(isInZip(info.path) ? innerName(info.path) : info.path)
      ..size = info.size
      ..mtime = info.mtime
      ..fingerprint = info.fingerprint
      ..format = info.format
      ..metaTitle = info.title
      ..metaAuthor = info.author
      ..metaSeries = info.series
      ..metaSeriesIndex = info.seriesIndex
      ..description = info.description
      ..publisher = info.publisher
      ..language = info.language
      ..published = info.published
      ..textBytes = info.textBytes
      ..pages = info.pages
      ..missing = false;
    _applyFolder(b, lf);
  }

  Book _newBook(BookInfo info, LibFolder lf) {
    final b = Book(
      id: 0,
      uid: newUid(),
      path: info.path,
      root: lf.path,
      relDir: '',
      fileName: '',
      size: 0,
      mtime: 0,
      fingerprint: '',
      format: info.format,
      kind: lf.kind,
      title: '',
      addedAt: nowSec(),
    );
    _apply(b, info, lf);
    return b;
  }

  Future<void> _saveCover(String fingerprint, Uint8List jpg) async {
    try {
      await writeFileSafely(Covers.I.fileForFp(fingerprint), jpg);
      Covers.I.version++;
    } catch (_) {}
  }

  /// Re-applies the file-name rules to every book (after a folder setting changes).
  void reapplyFolders() {
    Db.I.raw.execute('BEGIN');
    for (final b in _books) {
      final lf = Settings.I.folderFor(outerPath(b.path));
      if (lf == null) continue;
      _applyFolder(b, lf);
      Db.I.updateFile(b);
    }
    Db.I.raw.execute('COMMIT');
    changed();
  }

  // ---------------- watching ----------------

  void startWatching() {
    for (final w in _watchers) {
      w.cancel();
    }
    _watchers.clear();
    if (!Settings.I.watchFolders) return;
    for (final lf in Settings.I.folders) {
      if (!Directory(lf.path).existsSync()) continue;
      try {
        _watchers.add(Directory(lf.path).watch(recursive: true).listen((e) {
          final ext = p.extension(e.path).toLowerCase();
          if (bookExtensions.contains(ext) || ext == '.zip' || e.isDirectory) {
            _watchDebounce?.cancel();
            _watchDebounce = Timer(const Duration(seconds: 4), scan);
          }
        }, onError: (_) {}));
      } catch (e) {
        AppLog.I.warn('Can\'t watch ${lf.path} for changes: $e');
      }
    }
  }

  void resetAll() {
    Db.I.resetLibrary();
    load();
  }
}

/// Cover thumbnails, cached on disk (Cache\covers).
class Covers extends ChangeNotifier {
  Covers._();
  static final Covers I = Covers._();
  int version = 0;

  String fileForFp(String fp) => p.join(AppPaths.I.thumbs, '$fp.jpg');
  String fileFor(Book b) => fileForFp(b.fingerprint);

  File? cached(Book b) {
    final f = File(fileFor(b));
    return f.existsSync() ? f : null;
  }

  /// After two unclean exits in a row, covers aren't made in the background.
  bool safeMode = false;

  /// Remakes covers that are missing (for example after the cache was cleared).
  void queueMissing() {
    const name = 'Making covers';
    if (safeMode || Jobs.I.isQueued(name)) return;
    final todo = Library.I.books.where((b) => !b.missing && cached(b) == null).toList();
    if (todo.isEmpty) return;
    Jobs.I.add(Job(name, (job) async {
      job.progress(0, total: todo.length, detail: 'covers');
      var done = 0, made = 0;
      for (var i = 0; i < todo.length; i += 8) {
        if (!await job.checkpoint()) break;
        final batch = todo.sublist(i, min(i + 8, todo.length));
        final paths = batch.where((b) => b.format != 'pdf').map((b) => b.path).toList();
        final infos = await inspectInIsolate(paths, Library.I.zipPasswords);
        for (final info in infos) {
          if (info.cover != null) {
            await writeFileSafely(fileForFp(info.fingerprint), info.cover!);
            made++;
          }
        }
        for (final b in batch.where((b) => b.format == 'pdf')) {
          final insp = Library.I.pdfInspector;
          if (insp == null) continue;
          try {
            final path = isInZip(b.path) ? await Library.I.extractFromZip(b.path) : b.path;
            final (_, cover) = await insp(path);
            if (cover != null) {
              await writeFileSafely(fileFor(b), cover);
              made++;
            }
          } catch (_) {}
        }
        done += batch.length;
        version++;
        job.progress(done, detail: batch.last.cardTitle);
        notifyListeners();
      }
      notifyListeners();
      return '$made covers made';
    }, canPause: true));
  }

  Future<int> cacheSize() async {
    var total = 0;
    final d = Directory(AppPaths.I.thumbs);
    if (!await d.exists()) return 0;
    await for (final f in d.list()) {
      if (f is File) total += await f.length();
    }
    return total;
  }
}

// Isolate helpers. They're top-level on purpose: a closure made inside a method
// can carry the object it belongs to, which can't be sent to another isolate.

Future<List<BookInfo>> inspectInIsolate(List<String> paths, List<String> passwords) =>
    Isolate.run(() => [for (final x in paths) inspectBook(x, passwords: passwords)]);

Future<Uint8List?> readZipInIsolate(String zip, String inner, List<String> passwords) =>
    Isolate.run(() => readZipEntry(zip, inner, passwords: passwords));

Future<List<(String, int, int)>> listFilesInIsolate(String root) => Isolate.run(() => Library.listFiles(root));

Future<List<(String, List<(String, int)>)>> listZipsInIsolate(List<String> zips) => Isolate.run(() => [
      for (final z in zips)
        (z, () {
          try {
            return zipBookEntries(z);
          } catch (_) {
            return <(String, int)>[];
          }
        }())
    ]);

Future<List<String>> passwordsInIsolate(List<String> roots) => Isolate.run(() => passwordsFromFiles(roots));
