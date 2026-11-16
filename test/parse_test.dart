import 'package:flutter_test/flutter_test.dart';
import 'package:sable/core/parse.dart';

void main() {
  ParsedName ln(String rel, String f) => parseBookName(f, relDir: rel, seriesFromFolder: true);

  test('light novel volume numbers in their many spellings', () {
    final cases = <(String, String, String, double?, String)>[
      ('86 - EIGHTY-SIX', '86—EIGHTY-SIX - LN 06.epub', '86 - EIGHTY-SIX', 6, ''),
      ('Classroom of the Elite (Youkoso Jitsuryoku Shijou Shugi no Kyoushitsu e)', 'Classroom of the Elite Vol-2.epub', 'Classroom of the Elite (Youkoso Jitsuryoku Shijou Shugi no Kyoushitsu e)', 2, ''),
      ('Classroom of the Elite (Youkoso Jitsuryoku Shijou Shugi no Kyoushitsu e)/Fan Translation', 'Youkoso Jitsuryoku Shijou Shugi no Kyoushitsu e vol.12.epub', 'Classroom of the Elite (Youkoso Jitsuryoku Shijou Shugi no Kyoushitsu e)', 12, 'Fan Translation'),
      ('Boku no Kanojo Sensei', 'Boku no Kanojo Sensei volume 9.epub', 'Boku no Kanojo Sensei', 9, ''),
      ('Mushoku Tensei/Light Novel', 'Mushoku Tensei - Jobless Reincarnation Volume-11.epub', 'Mushoku Tensei', 11, ''),
      ('Mushoku Tensei/Web Novel/PDFs', 'Mushoku Tensei Volume 09 - Sylphiette Chapter.pdf', 'Mushoku Tensei', 9, 'Web Novel'),
      ('Dungeon Defense/Volume 1/EPUB', 'Dungeon Defense - Volume 01.epub', 'Dungeon Defense', 1, ''),
      ('Kokoro Connect', 'Kokoro Connect - Volume 02  Premium.epub', 'Kokoro Connect', 2, ''),
      ('The Kept Man of the Princess Knight', 'The Kept Man of the Princess Knight - Volume 03 [Yen Press][Kobo].epub', 'The Kept Man of the Princess Knight', 3, ''),
      ('Oregairu LN', '(1) Volume A.pdf', 'Oregairu', 1, ''),
      ('Goblin Slayer', 'Goblin Slayer, Vol. 3 (light no - Kumo Kagyu.pdf', 'Goblin Slayer', 3, ''),
      ('Even If This Love Disappears Tonight', 'Even If This Love Disappears Tonight vol 1.epub', 'Even If This Love Disappears Tonight', 1, ''),
      ('Tensei Shitara Slime Datta Ken WN', 'Tensei Shitara Slime Datta Ken - Volume 05 (WN Chapter 084-097) - Saint Demon Confrontation Arc.pdf', 'Tensei Shitara Slime Datta Ken', 5, 'Web Novel'),
      ('Der Werwolf - The Annals of Veight', 'Marchen der Werwolf - LN 04 Premium Ver.epub', 'Der Werwolf - The Annals of Veight', 4, ''),
      ('Is It Wrong To Pick Up Girls in The Dungeon', 'Is It Wrong to Try to Pick Up G - V10.epub', 'Is It Wrong To Pick Up Girls in The Dungeon', 10, ''),
      ('Is It Wrong To Pick Up Girls in The Dungeon', 'Is It Wrong to Try to Pick Up G -V2.epub', 'Is It Wrong To Pick Up Girls in The Dungeon', 2, ''),
    ];
    for (final c in cases) {
      final r = ln(c.$1, c.$2);
      expect(r.series, c.$3, reason: c.$2);
      expect(r.volume, c.$4, reason: c.$2);
      expect(r.edition, c.$5, reason: c.$2);
    }
  });

  test('subtitles and clean titles', () {
    final r = ln('Sevens', 'Sevens Volume 17 - I Need to get Some Chapter Title Naming Sense, Seventeenth Generation.epub');
    expect(r.volume, 17);
    expect(r.subtitle, 'I Need to get Some Chapter Title Naming Sense, Seventeenth Generation');
    final k = ln('Kobold King', 'Kobold King - LN 02 Premium.epub');
    expect(k.subtitle, isNull);
    final ff = ln('Final Fantasy XV - The Dawn of the Future - LN', 'Final Fantasy XV - The Dawn of the Future - LN.epub');
    expect(ff.volume, isNull);
    expect(ff.series, 'Final Fantasy XV - The Dawn of the Future');
  });

  test('books and collection packs', () {
    final a = parseBookName('Carol Berg - [Books of the Rai-kirah 03] - Restoration (v5.0) (epub).epub');
    expect(a.series, 'Books of the Rai-kirah');
    expect(a.volume, 3);
    expect(a.title, 'Restoration');
    final b = parseBookName('Pierce Brown - [Red Rising 01] - Red Rising (v5.0) (epub).epub');
    expect(b.series, 'Red Rising');
    expect(b.volume, 1);
    final c = parseBookName('1987 - Norwegian Wood.epub', relDir: 'Haruki Murakami');
    expect(c.series, isNull);
    expect(c.volume, isNull);
    final d = parseBookName('Bittersweet_Sarah_Ockler.epub');
    expect(d.title, 'Bittersweet Sarah Ockler');
  });

  test('natural order', () {
    final l = ['Vol 10', 'Vol 2', 'Vol 1']..sort(naturalCompare);
    expect(l, ['Vol 1', 'Vol 2', 'Vol 10']);
  });
}
