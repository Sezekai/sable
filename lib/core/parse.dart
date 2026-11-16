import 'package:path/path.dart' as p;

/// What a file name and its folders say about a book.
class ParsedName {
  ParsedName({
    required this.title,
    this.series,
    this.volume,
    this.subtitle,
    this.edition = '',
    this.author,
  });

  /// Clean title from the file name (no volume tags, shop names or extensions).
  final String title;

  /// Series name, if the book is part of one.
  final String? series;
  final double? volume;

  /// Text after the volume number ("The Seventh Generation was…").
  final String? subtitle;

  /// "Web Novel", "Fan Translation"… ('' for the main edition).
  final String edition;
  final String? author;

  @override
  String toString() => 'ParsedName($title | $series | $volume | $subtitle | $edition)';
}

const bookExtensions = {'.epub', '.pdf', '.mobi', '.azw3', '.azw', '.prc'};

String formatOf(String name) {
  final e = p.extension(name).toLowerCase();
  return switch (e) {
    '.epub' => 'epub',
    '.pdf' => 'pdf',
    '.azw3' || '.azw' => 'azw3',
    _ => 'mobi',
  };
}

final _volRe = RegExp(
    r'(?:^|[\s,\-–—_(\[])(?:LN|Vol(?:ume)?)\s*[.\-_]?\s*(\d{1,3}(?:\.\d)?)(?!\d)',
    caseSensitive: false);

/// "Is It Wrong to Try to Pick Up G - V10", "-V2": a capital V right after a dash or space.
final _vRe = RegExp(r'(?:^|[\s\-–—])V\s?(\d{1,3})(?!\d)');
final _bracketSeriesRe = RegExp(r'\[([^\[\]]+?)\s+(\d{1,3}(?:\.\d)?)\]');
final _leadingNumRe = RegExp(r'^\((\d{1,3})\)\s*');
final _trailingNumRe = RegExp(r'^(.*?\D)\s+(\d{1,3}(?:\.\d)?)$');

/// Shop, version and format tags that don't belong in a title.
String cleanName(String s) {
  var out = s;
  out = out.replaceAll(RegExp(r'\[(?:[^\[\]]*(?:press|kobo|j-?novel|seven seas|club|epub|mobi|pdf|team|tmrg|kindle|amazon|digital|official|retail|azw3?)[^\[\]]*)\]', caseSensitive: false), ' ');
  out = out.replaceAll(RegExp(r'\((?:v\d+(?:\.\d+)?|epub|mobi|pdf|azw3|retail|digital)\)', caseSensitive: false), ' ');
  out = out.replaceAll(RegExp(r'\bPremium(?:\s+Ver(?:sion)?\.?)?\b', caseSensitive: false), ' ');
  out = out.replaceAll(RegExp(r'\bUnabridged\b', caseSensitive: false), ' ');
  out = out.replaceAll('_', ' ');
  out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
  out = trimSeparators(out);
  return out;
}

String trimSeparators(String s) {
  var out = s.trim();
  final sep = RegExp(r'^[\s\-–—,:;.]+|[\s\-–—,:;]+$');
  out = out.replaceAll(sep, '').trim();
  return out;
}

/// Folder names inside a series folder that only sort files by format or volume.
final _plainFolderRe = RegExp(
    r'^(?:epubs?|pdfs?|e-?books?|zips?|mobi|azw3?|books?|light\s*novels?|ln|official(?:\s+translation)?|volume\s*\d+|vol\.?\s*\d+|v\d+|files?|downloads?)$',
    caseSensitive: false);

/// Reads a book's file name, plus the folders under its library folder.
///
/// [relDir] is the folder relative to the library folder ('' at the top).
/// In a light novel folder, the first folder is the series.
ParsedName parseBookName(String fileName, {String relDir = '', bool seriesFromFolder = false}) {
  var base = fileName;
  for (var i = 0; i < 2; i++) {
    final e = p.extension(base).toLowerCase();
    if (bookExtensions.contains(e) || e == '.zip') base = p.basenameWithoutExtension(base);
  }
  final parts = relDir.isEmpty ? <String>[] : p.split(relDir).where((x) => x.isNotEmpty && x != '.').toList();
  String? folderSeries;
  var edition = '';
  if (seriesFromFolder && parts.isNotEmpty) {
    folderSeries = cleanName(parts.first);
    final extra = parts.skip(1).where((x) => !_plainFolderRe.hasMatch(x.trim())).map((x) => x.trim()).toList();
    // "Oregairu LN" is the series Oregairu; "Slime Datta Ken WN" is its web novel.
    final suffix = RegExp(r'\s+[-–—]?\s*(LN|WN)$', caseSensitive: false).firstMatch(folderSeries);
    if (suffix != null) {
      if (suffix.group(1)!.toUpperCase() == 'WN') extra.insert(0, 'Web Novel');
      folderSeries = folderSeries.substring(0, suffix.start).trim();
    }
    edition = _editionLabel(extra.join(' · '));
  }

  double? volume;
  String? series;
  String? subtitle;
  var title = base;

  // "(1) Volume A"
  final lead = _leadingNumRe.firstMatch(title);
  double? leadNum;
  if (lead != null) {
    leadNum = double.tryParse(lead.group(1)!);
    title = title.substring(lead.end);
  }

  // "Carol Berg - [Books of the Rai-kirah 03] - Restoration"
  final bs = _bracketSeriesRe.firstMatch(title);
  if (bs != null) {
    series = cleanName(bs.group(1)!);
    volume = double.tryParse(bs.group(2)!);
    final after = trimSeparators(title.substring(bs.end));
    subtitle = after.isEmpty ? null : cleanName(after);
    title = subtitle ?? series;
  } else {
    final cleaned = cleanName(title);
    final m = _volRe.firstMatch(cleaned) ?? _vRe.firstMatch(cleaned);
    if (m != null) {
      volume = double.tryParse(m.group(1)!);
      final before = trimSeparators(cleaned.substring(0, m.start));
      var after = cleaned.substring(m.end);
      // "(WN Chapter 084-097)" right after the number is a note, not the subtitle.
      after = after.replaceFirst(RegExp(r'^\s*\([^)]*\)'), '');
      after = trimSeparators(after);
      series = before.isEmpty ? null : before;
      subtitle = after.isEmpty ? null : after;
      title = subtitle ?? (series ?? cleaned);
    } else {
      // "Final Fantasy XV - The Dawn of the Future - LN"
      var t = cleaned.replaceFirst(RegExp(r'[\s\-–—]+LN$', caseSensitive: false), '');
      final tn = _trailingNumRe.firstMatch(t);
      if (folderSeries != null && tn != null) {
        series = trimSeparators(tn.group(1)!);
        volume = double.tryParse(tn.group(2)!);
        title = series;
      } else {
        title = t;
      }
    }
  }
  volume ??= leadNum;

  if (folderSeries != null && folderSeries.isNotEmpty) {
    series = folderSeries;
  }
  if (title.isEmpty) title = series ?? base;
  return ParsedName(
    title: title,
    series: series,
    volume: volume,
    subtitle: subtitle,
    edition: edition,
  );
}

String _editionLabel(String s) {
  final l = s.toLowerCase();
  if (l.isEmpty) return '';
  if (RegExp(r'\b(web\s*novel|wn)\b').hasMatch(l)) return 'Web Novel';
  if (l.contains('fan')) return 'Fan Translation';
  return s;
}

/// Lower-case letters and digits only, for matching names.
String normKey(String s) => s
    .toLowerCase()
    .replaceAll('&', 'and')
    .replaceAll(RegExp(r"['’`]"), '')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

String volumeLabel(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

int naturalCompare(String a, String b) {
  final ra = RegExp(r'(\d+)|(\D+)');
  final ta = ra.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
  final tb = ra.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
  for (var i = 0; i < ta.length && i < tb.length; i++) {
    final x = ta[i], y = tb[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    int c;
    if (nx != null && ny != null) {
      c = nx.compareTo(ny);
      if (c == 0) c = x.length.compareTo(y.length);
    } else {
      c = x.compareTo(y);
    }
    if (c != 0) return c;
  }
  return ta.length.compareTo(tb.length);
}
