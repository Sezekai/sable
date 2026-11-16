# Sable — product notes

## Who and what it's for

One owner, reading books and light novels on a Windows laptop (and later an Honor Magic V3 phone). It's the book companion to Shiori (manga, comics and art books) and feels like Lithium on Android: a cover grid, a calm reader with few settings, and full history and stats.

The collection, as found in November 2026:

- `E:\Documents\LIGHT NOVELS`: 101 series folders, 539 EPUB, 194 PDF, 32 ZIP (about 8 GB). Some series are PDF only; many volumes exist as both EPUB and PDF.
- `E:\Documents\BOOKS`: about 60 EPUB and 8 PDF.
- `E:\Documents\BOOKS I OWN`: art and game books as PDFs (kept here for now).
- `E:\Documents\BOOK Collections`: downloaded packs, 1,071 EPUB, 1,619 MOBI, 638 TXT (TXT is skipped). Shown with a toggle to hide them.
- Islamic Books on the SSD is left out on purpose.

## Constraints

- The library is **read-only**. Sable never moves, renames, edits or deletes the owner's books. It writes only its own data and caches.
- Large libraries on a hard drive (E:) that may be disconnected.
- Simple and compact: few reading options, like Lithium.

## Stages

1. **This release:** the complete PC app.
2. **Next:** the Android app (same codebase): pairs with the PC on home WiFi, browses the whole library offline with covers, history and stats, downloads chosen books or series (never everything automatically), and syncs positions, history, ratings, favourites, tags and bookmarks both ways. Its sync is separate from Shiori's.

## Decisions for this app (STANDARDS.md "App chooses" and "When relevant")

- **Toolkit:** Flutter, like Shiori, so the Android app shares the code.
- **Book engine changes:** `assets/reader/paginator.js` (from foliate-js) has one change, marked "Sable": no scrollbar in scroll mode.
- **Book engine:** EPUB and MOBI/AZW3 are laid out by foliate-js inside WebView2 (Windows) or the system web view (Android), loaded from a server on `127.0.0.1` only. PDFs are drawn natively with pdfrx (PDFium).
- **Positions:** EPUB CFI plus a percentage, not page numbers, because pages differ between a PC spread and a phone. Stats count "pages" of 1,500 letters, the same unit the book engine uses, so numbers match across devices.
- **One library:** Book / Light novel is a field set per folder (and editable per book), not a section.
- **Same volume, several formats:** grouped as one volume; EPUB is preferred, then AZW3, MOBI, PDF; a copy outside a ZIP is preferred to one inside.
- **Storage format:** SQLite for the library (`library.db`), JSON for settings and look. The database is backed up daily, keeping 7 copies.
- **Watching folders:** yes, plus a quick rescan at start-up.
- **Rail:** Library, History, Stats, Settings, then Keys and Log.
- **Keys added for this app:** R random book; in the reader D one/two pages, T contents, B bookmark, V favourite, N next volume, + − text size.

## Differences from the standards, with reasons

- **Appearance:** two themes (OLED black and Starlight), each editable colour by colour with its own accent (preset or custom), saved over the theme with a reset per colour and per theme, plus App size and Reader controls size. This is in Settings → Look; the full Appearance screen from DESIGN.md isn't built.
- **Fonts:** Inter and JetBrains Mono for the app; Literata and Inter for reading (plus Georgia, Palatino and the book's own).
- **Files on disk:** the Recycle Bin, move log and undo rules don't apply, because Sable moves and deletes none of the owner's files.
- **Sensitive content:** no NSFW filters; the owner didn't ask for them.
- **GPU chip:** not shown. Sable has no GPU jobs.
- **Window snapping:** the title bar is drawn by the app (window_manager). Edge snapping and dragging work; the snap-layout flyout on the maximise button doesn't.

## Never in it

- Online stores, accounts or tracking services.
- Editing, converting or moving library files.
- TXT and audiobook files.
- Highlights, notes and dictionary (not wanted yet).
