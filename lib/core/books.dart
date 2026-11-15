import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'parse.dart';

/// A book inside a ZIP is addressed as "C:\…\file.zip|inner/name.epub".
const zipSep = '|';

bool isInZip(String path) => path.contains(zipSep);
String outerPath(String path) => path.split(zipSep).first;
String innerName(String path) => path.contains(zipSep) ? path.substring(path.indexOf(zipSep) + 1) : '';

/// What reading a book file found. Made in a background isolate.
class BookInfo {
  BookInfo(this.path);
  final String path;
  int size = 0;
  int mtime = 0;
  String fingerprint = '';
  String format = 'epub';
  String? title;
  String? author;
  String? series;
  double? seriesIndex;
  String? description;
  String? publisher;
  String? language;
  String? published;

  /// Bytes of text (the same measure the reader uses for locations).
  int textBytes = 0;

  /// PDFs: page count, filled in on the main side.
  int pages = 0;

  /// A ready JPG cover, 360 px wide.
  Uint8List? cover;
  String? error;
}

String fingerprintOf(RandomAccessFile f, int size) {
  const chunk = 65536;
  final b = BytesBuilder(copy: false);
  b.add(utf8.encode('$size|'));
  f.setPositionSync(0);
  b.add(f.readSync(size < chunk ? size : chunk));
  if (size > chunk * 2) {
    f.setPositionSync(size - chunk);
    b.add(f.readSync(chunk));
  }
  return sha1.convert(b.takeBytes()).toString();
}

String fingerprintBytes(Uint8List bytes) {
  const chunk = 65536;
  final b = BytesBuilder(copy: false);
  b.add(utf8.encode('${bytes.length}|'));
  b.add(bytes.sublist(0, bytes.length < chunk ? bytes.length : chunk));
  if (bytes.length > chunk * 2) b.add(bytes.sublist(bytes.length - chunk));
  return sha1.convert(b.takeBytes()).toString();
}

/// Lists the books inside a ZIP (names only), skipping folders and other files.
List<(String, int)> zipBookEntries(String zipPath) {
  final input = InputFileStream(zipPath);
  try {
    final arc = ZipDecoder().decodeStream(input);
    return [
      for (final f in arc.files)
        if (f.isFile && bookExtensions.contains(p.extension(f.name).toLowerCase())) (f.name, f.size)
    ];
  } finally {
    input.closeSync();
  }
}

/// Reads the bytes of one book stored inside a ZIP.
Uint8List? readZipEntry(String zipPath, String name) {
  final input = InputFileStream(zipPath);
  try {
    final arc = ZipDecoder().decodeStream(input);
    final f = arc.findFile(name);
    return f?.readBytes();
  } finally {
    input.closeSync();
  }
}

/// Reads one book file (or a book inside a ZIP): fingerprint, details and cover.
BookInfo inspectBook(String path, {bool withCover = true}) {
  final info = BookInfo(path);
  final name = isInZip(path) ? innerName(path) : path;
  info.format = formatOf(name);
  try {
    final outer = File(outerPath(path));
    final st = outer.statSync();
    info.mtime = st.modified.millisecondsSinceEpoch ~/ 1000;
    if (isInZip(path)) {
      final bytes = readZipEntry(outerPath(path), innerName(path));
      if (bytes == null) throw 'it isn\'t in the ZIP any more';
      info.size = bytes.length;
      info.fingerprint = fingerprintBytes(bytes);
      _readFrom(info, bytes: bytes, withCover: withCover);
    } else {
      info.size = st.size;
      final raf = outer.openSync();
      try {
        info.fingerprint = fingerprintOf(raf, st.size);
      } finally {
        raf.closeSync();
      }
      _readFrom(info, path: path, withCover: withCover);
    }
  } catch (e) {
    info.error = '$e';
  }
  return info;
}

void _readFrom(BookInfo info, {String? path, Uint8List? bytes, required bool withCover}) {
  switch (info.format) {
    case 'epub':
      _readEpub(info, path: path, bytes: bytes, withCover: withCover);
    case 'mobi' || 'azw3':
      _readMobi(info, bytes ?? File(path!).readAsBytesSync(), withCover: withCover);
    case 'pdf':
      // Page count and cover come from the PDF engine on the main side.
      break;
  }
}

// ---------------- EPUB ----------------

void _readEpub(BookInfo info, {String? path, Uint8List? bytes, required bool withCover}) {
  InputFileStream? input;
  try {
    final Archive arc;
    if (bytes != null) {
      arc = ZipDecoder().decodeBytes(bytes);
    } else {
      input = InputFileStream(path!);
      arc = ZipDecoder().decodeStream(input);
    }
    String text(String n) {
      final f = arc.findFile(n);
      if (f == null) throw 'missing $n';
      return utf8.decode(f.readBytes() ?? Uint8List(0), allowMalformed: true);
    }

    final container = XmlDocument.parse(text('META-INF/container.xml'));
    final rootfile = container.findAllElements('rootfile').firstOrNull?.getAttribute('full-path');
    if (rootfile == null) throw 'no package file';
    final opfDir = p.posix.dirname(rootfile) == '.' ? '' : '${p.posix.dirname(rootfile)}/';
    final opf = XmlDocument.parse(text(rootfile));
    final meta = opf.findAllElements('metadata').firstOrNull ?? opf.rootElement;

    String? dc(String local) {
      for (final e in meta.descendantElements) {
        if (e.name.local == local) {
          final t = e.innerText.trim();
          if (t.isNotEmpty) return t;
        }
      }
      return null;
    }

    info.title = dc('title');
    final creators = [
      for (final e in meta.descendantElements)
        if (e.name.local == 'creator' && e.innerText.trim().isNotEmpty) e
    ];
    // Prefer authors over illustrators and translators.
    final authors = creators.where((e) {
      final role = e.getAttribute('opf:role') ?? e.getAttribute('role');
      if (role != null) return role == 'aut';
      final id = e.getAttribute('id');
      if (id == null) return true;
      final refine = meta.descendantElements
          .where((m) => m.getAttribute('refines') == '#$id' && m.getAttribute('property') == 'role')
          .firstOrNull;
      final refined = refine?.innerText.trim() ?? '';
      return refined.isEmpty || refined == 'aut';
    }).toList();
    final names = (authors.isEmpty ? creators : authors).map((e) => e.innerText.trim()).toSet().toList();
    if (names.isNotEmpty) info.author = names.take(3).join(', ');
    final desc = dc('description');
    if (desc != null) info.description = stripHtml(desc);
    info.publisher = dc('publisher');
    info.language = dc('language');
    info.published = dc('date');

    // Series: calibre's tags, or EPUB 3 collections.
    for (final e in meta.descendantElements) {
      final n = e.getAttribute('name');
      if (n == 'calibre:series') info.series = e.getAttribute('content');
      if (n == 'calibre:series_index') info.seriesIndex = double.tryParse(e.getAttribute('content') ?? '');
      if (e.getAttribute('property') == 'belongs-to-collection' && info.series == null) {
        info.series = e.innerText.trim();
        final id = e.getAttribute('id');
        if (id != null) {
          for (final r in meta.descendantElements) {
            if (r.getAttribute('refines') == '#$id' && r.getAttribute('property') == 'group-position') {
              info.seriesIndex = double.tryParse(r.innerText.trim());
            }
          }
        }
      }
    }

    // Manifest and spine.
    final items = <String, XmlElement>{};
    for (final it in opf.findAllElements('item')) {
      final id = it.getAttribute('id');
      if (id != null) items[id] = it;
    }
    String resolve(String href) => p.posix.normalize('$opfDir${Uri.decodeFull(href)}');
    var total = 0;
    for (final ref in opf.findAllElements('itemref')) {
      if (ref.getAttribute('linear') == 'no') continue;
      final it = items[ref.getAttribute('idref')];
      final href = it?.getAttribute('href');
      if (href == null) continue;
      final f = arc.findFile(resolve(href));
      if (f != null) total += f.size;
    }
    info.textBytes = total;

    if (withCover) {
      XmlElement? coverItem = items.values.where((i) => (i.getAttribute('properties') ?? '').split(' ').contains('cover-image')).firstOrNull;
      if (coverItem == null) {
        final metaCover = meta.descendantElements.where((e) => e.getAttribute('name') == 'cover').firstOrNull?.getAttribute('content');
        if (metaCover != null) coverItem = items[metaCover] ?? items.values.where((i) => i.getAttribute('href') == metaCover).firstOrNull;
      }
      bool isImage(XmlElement i) => (i.getAttribute('media-type') ?? '').startsWith('image/');
      coverItem ??= items.values.where((i) => isImage(i) && ((i.getAttribute('id') ?? '') + (i.getAttribute('href') ?? '')).toLowerCase().contains('cover')).firstOrNull;
      coverItem ??= items.values.where(isImage).firstOrNull;
      final href = coverItem?.getAttribute('href');
      if (href != null) {
        final f = arc.findFile(resolve(href));
        final b = f?.readBytes();
        if (b != null) info.cover = makeCoverJpg(b);
      }
    }
  } finally {
    input?.closeSync();
  }
}

String stripHtml(String s) {
  var out = s.replaceAll(RegExp(r'<br\s*/?>|</p>', caseSensitive: false), '\n');
  out = out.replaceAll(RegExp(r'<[^>]+>'), '');
  out = out
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ');
  out = out.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n\s*\n+'), '\n\n');
  return out.trim();
}

// ---------------- MOBI / AZW3 ----------------

void _readMobi(BookInfo info, Uint8List b, {required bool withCover}) {
  final bd = ByteData.sublistView(b);
  if (b.length < 78) throw 'too short';
  final n = bd.getUint16(76);
  List<int> offsets = [for (var i = 0; i < n; i++) bd.getUint32(78 + i * 8)];
  Uint8List record(int i) => b.sublist(offsets[i], i + 1 < n ? offsets[i + 1] : b.length);
  final r0 = record(0);
  final h = ByteData.sublistView(r0);
  info.textBytes = h.getUint32(4);
  if (r0.length < 132 || String.fromCharCodes(r0.sublist(16, 20)) != 'MOBI') {
    info.title = String.fromCharCodes(b.sublist(0, 32).takeWhile((c) => c != 0));
    return;
  }
  final headerLen = h.getUint32(20);
  final encoding = h.getUint32(28);
  String dec(List<int> x) => encoding == 65001 ? utf8.decode(x, allowMalformed: true) : latin1.decode(x, allowInvalid: true);
  final nameOff = h.getUint32(84), nameLen = h.getUint32(88);
  if (nameOff + nameLen <= r0.length) info.title = dec(r0.sublist(nameOff, nameOff + nameLen)).trim();
  final firstImage = h.getUint32(108);
  final exthFlags = h.getUint32(128);
  int? coverOffset, thumbOffset;
  final authors = <String>[];
  if (exthFlags & 0x40 != 0) {
    var o = 16 + headerLen;
    if (o + 12 <= r0.length && String.fromCharCodes(r0.sublist(o, o + 4)) == 'EXTH') {
      final count = h.getUint32(o + 8);
      o += 12;
      for (var i = 0; i < count && o + 8 <= r0.length; i++) {
        final type = h.getUint32(o), len = h.getUint32(o + 4);
        if (len < 8 || o + len > r0.length) break;
        final data = r0.sublist(o + 8, o + len);
        switch (type) {
          case 100:
            authors.add(dec(data).trim());
          case 101:
            info.publisher = dec(data).trim();
          case 103:
            info.description = stripHtml(dec(data));
          case 106:
            info.published = dec(data).trim();
          case 503:
            info.title = dec(data).trim();
          case 524:
            info.language = dec(data).trim();
          case 201:
            if (data.length >= 4) coverOffset = ByteData.sublistView(data).getUint32(0);
          case 202:
            if (data.length >= 4) thumbOffset = ByteData.sublistView(data).getUint32(0);
        }
        o += len;
      }
    }
  }
  if (authors.isNotEmpty) info.author = authors.toSet().take(3).join(', ');
  if (withCover && firstImage != 0xFFFFFFFF) {
    final idx = firstImage + (coverOffset ?? thumbOffset ?? 0);
    if (idx < n) {
      final c = makeCoverJpg(record(idx));
      if (c != null) info.cover = c;
    }
  }
}

// ---------------- covers ----------------

/// Decodes an image, scales it to 360 px wide and saves it as JPG.
Uint8List? makeCoverJpg(Uint8List bytes) {
  try {
    final im = img.decodeImage(bytes);
    if (im == null) return null;
    final small = im.width > 360 ? img.copyResize(im, width: 360, interpolation: img.Interpolation.average) : im;
    return img.encodeJpg(small, quality: 85);
  } catch (_) {
    return null;
  }
}

/// BGRA pixels from the PDF engine to a cover JPG.
Uint8List? coverFromBgra(Uint8List bgra, int width, int height) {
  try {
    final im = img.Image.fromBytes(
        width: width, height: height, bytes: bgra.buffer, numChannels: 4, order: img.ChannelOrder.bgra);
    final small = im.width > 360 ? img.copyResize(im, width: 360, interpolation: img.Interpolation.average) : im;
    return img.encodeJpg(small, quality: 85);
  } catch (_) {
    return null;
  }
}
