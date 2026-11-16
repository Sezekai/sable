import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sable/core/books.dart';
import 'package:sable/core/samples.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sable_books'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('reads an EPUB: details, series, length and cover', () {
    final f = File(p.join(dir.path, 'Test - Vol. 2.epub'))
      ..writeAsBytesSync(makeSampleEpub(title: 'The Second One', author: 'A. Writer', series: 'Test Saga', index: 2));
    final info = inspectBook(f.path);
    expect(info.error, isNull);
    expect(info.format, 'epub');
    expect(info.title, 'The Second One');
    expect(info.author, 'A. Writer');
    expect(info.series, 'Test Saga');
    expect(info.seriesIndex, 2);
    expect(info.description, contains('made-up book'));
    expect(info.textBytes, greaterThan(20000));
    expect(info.cover, isNotNull);
    expect(info.fingerprint.length, 40);
  });

  test('reads a book inside a ZIP without unpacking it to disk', () {
    final arc = Archive()..addFile(ArchiveFile.bytes('inner/Book - LN 01.epub', makeSampleEpub(title: 'Zipped', author: 'Z')));
    final zip = File(p.join(dir.path, 'Book - LN 01.zip'))..writeAsBytesSync(ZipEncoder().encodeBytes(arc));
    final entries = zipBookEntries(zip.path);
    expect(entries.map((e) => e.$1), ['inner/Book - LN 01.epub']);
    final info = inspectBook('${zip.path}${zipSep}inner/Book - LN 01.epub');
    expect(info.error, isNull);
    expect(info.title, 'Zipped');
    expect(isInZip(info.path), isTrue);
    expect(outerPath(info.path), zip.path);
  });

  test('locked ZIPs open with a password from a password file', () {
    final arc = Archive()..addFile(ArchiveFile.bytes('Locked - LN 01.epub', makeSampleEpub(title: 'Locked', author: 'L')));
    final zip = p.join(dir.path, 'Locked - LN 01.zip');
    File(zip).writeAsBytesSync(ZipEncoder(password: 'sesame-123').encodeBytes(arc));
    File(p.join(dir.path, 'Password for many rars.txt')).writeAsStringSync('Password: sesame-123');
    final inner = '$zip${zipSep}Locked - LN 01.epub';
    expect(inspectBook(inner).error, contains('password'));
    final pws = passwordsFromFiles([dir.path]);
    expect(pws, contains('sesame-123'));
    final info = inspectBook(inner, passwords: pws);
    expect(info.error, isNull);
    expect(info.title, 'Locked');
  });

  test('a broken file reports an error instead of throwing', () {
    final f = File(p.join(dir.path, 'bad.epub'))..writeAsStringSync('not a zip');
    final info = inspectBook(f.path);
    expect(info.error, isNotNull);
  });

  test('a damaged MOBI still gets added (details from its name)', () {
    final f = File(p.join(dir.path, 'Broken.mobi'))..writeAsBytesSync(List.filled(200, 0));
    final info = inspectBook(f.path);
    expect(info.error, isNull);
    expect(info.fingerprint, isNotEmpty);
  });

  test('sample PDF is well formed', () {
    final pdf = makeSamplePdf(3, 'x');
    expect(String.fromCharCodes(pdf.sublist(0, 8)), '%PDF-1.4');
  });
}
