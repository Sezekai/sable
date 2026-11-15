import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;

/// Small made-up books for the self-test and unit tests.
Uint8List makeSampleEpub({
  required String title,
  required String author,
  String? series,
  double? index,
  int chapters = 4,
  int paragraphs = 40,
  int hue = 0,
}) {
  final arc = Archive();
  void add(String name, List<int> data, {bool store = false}) {
    final f = ArchiveFile.bytes(name, data);
    if (store) f.compression = CompressionType.none;
    arc.addFile(f);
  }

  add('mimetype', utf8.encode('application/epub+zip'), store: true);
  add('META-INF/container.xml', utf8.encode('''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>'''));
  final cover = img.Image(width: 600, height: 900);
  img.fill(cover, color: img.ColorRgb8(30 + hue % 120, 40, 90 + hue % 100));
  img.drawRect(cover, x1: 30, y1: 30, x2: 569, y2: 869, color: img.ColorRgb8(230, 230, 240), thickness: 6);
  add('OEBPS/cover.jpg', img.encodeJpg(cover, quality: 80));
  final items = StringBuffer();
  final spine = StringBuffer();
  final nav = StringBuffer();
  for (var c = 1; c <= chapters; c++) {
    final body = StringBuffer('<h1>Chapter $c</h1>');
    for (var i = 0; i < paragraphs; i++) {
      body.write('<p>This is paragraph ${i + 1} of chapter $c in $title. The night sky was full of stars, '
          'and the road ran on past the hills toward a town nobody in the story had seen before.</p>');
    }
    add('OEBPS/ch$c.xhtml', utf8.encode('''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter $c</title></head><body>$body</body></html>'''));
    items.writeln('<item id="ch$c" href="ch$c.xhtml" media-type="application/xhtml+xml"/>');
    spine.writeln('<itemref idref="ch$c"/>');
    nav.writeln('<li><a href="ch$c.xhtml">Chapter $c</a></li>');
  }
  add('OEBPS/nav.xhtml', utf8.encode('''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head>
<body><nav epub:type="toc"><ol>$nav</ol></nav></body></html>'''));
  add('OEBPS/content.opf', utf8.encode('''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">sable-sample-$title</dc:identifier>
    <dc:title>$title</dc:title>
    <dc:creator>$author</dc:creator>
    <dc:language>en</dc:language>
    <dc:description>&lt;p&gt;A made-up book used to check that Sable works.&lt;/p&gt;</dc:description>
    ${series == null ? '' : '<meta name="calibre:series" content="$series"/><meta name="calibre:series_index" content="${index ?? 1}"/>'}
    <meta name="cover" content="cover"/>
  </metadata>
  <manifest>
    <item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    $items
  </manifest>
  <spine>$spine</spine>
</package>'''));
  return Uint8List.fromList(ZipEncoder().encodeBytes(arc));
}

/// A plain PDF with a line of text on each page.
Uint8List makeSamplePdf(int pages, String label) {
  final objs = <String>[];
  final kids = <String>[];
  // 1: catalog, 2: pages, 3: font, then page + content pairs.
  objs.add('<< /Type /Catalog /Pages 2 0 R >>');
  objs.add(''); // pages, filled below
  objs.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  for (var i = 0; i < pages; i++) {
    final pageNo = objs.length + 1;
    final contentNo = pageNo + 1;
    kids.add('$pageNo 0 R');
    objs.add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 595] /Resources << /Font << /F1 3 0 R >> >> /Contents $contentNo 0 R >>');
    final stream = 'BT /F1 24 Tf 60 500 Td ($label page ${i + 1}) Tj ET';
    objs.add('<< /Length ${stream.length} >>\nstream\n$stream\nendstream');
  }
  objs[1] = '<< /Type /Pages /Kids [${kids.join(' ')}] /Count $pages >>';
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objs.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return Uint8List.fromList(latin1.encode(out.toString()));
}
