# Sable

A library and reader for books and light novels, built to feel like Lithium: clean, compact and quick, with an OLED black or Starlight look and gradient accents. Books and light novels live in one library, with series, history, stats, ratings, favourites and tags.

This is stage 1: the complete Windows app. Stage 2 adds the Android app, which syncs with this PC over home WiFi and keeps downloaded books for offline reading.

## Install and update

1. Download `Sable-vX.Y.Z-windows.zip` from the latest [release](../../releases).
2. Unzip it to `E:\Pictures\`. You get `E:\Pictures\Sable\App\Sable.exe`.
3. Run `Sable.exe`. No installer and no admin rights are needed.

EPUB and MOBI books are shown with Microsoft Edge WebView2, which comes with Windows 11. If it's ever missing, Sable says so and how to get it.

**Updating:** replace the `App` folder with the new one. Your library, history, settings and covers are kept, because they live outside it.

## Where things live

| What | Where |
| --- | --- |
| The program | `E:\Pictures\Sable\App\` (replaced by each update) |
| Cover thumbnails | `E:\Pictures\Sable\Cache\covers\` |
| Books copied out of ZIPs while reading | `E:\Pictures\Sable\Cache\books\` (cleared down to 1 GB at start-up) |
| Library database: books, history, ratings, tags, bookmarks | `%LOCALAPPDATA%\Sable\library.db` |
| Settings and look | `%LOCALAPPDATA%\Sable\settings.json`, `appearance.json` |
| Book engine (WebView2) data | `%LOCALAPPDATA%\Sable\WebView2\` |
| Logs and crash logs | `%LOCALAPPDATA%\Sable\logs\` |
| Database backups (last 7 days) | `%LOCALAPPDATA%\Sable\backups\` |

Settings → Storage shows each place with its size, and can open, move or clear it.

## Features

### Library
- **One library** for books and light novels. Each folder is marked Books or Light novels, and can be marked as a **Collection** (downloaded packs). **Collections shown / hidden** in the toolbar hides those books in one click.
- Default folders: `E:\Documents\LIGHT NOVELS` (light novels), `E:\Documents\BOOKS`, `E:\Documents\BOOKS I OWN` and `E:\Documents\BOOK Collections` (a collection).
- Reads **EPUB, PDF, MOBI and AZW3**, also when they're inside a **ZIP** (read straight from the ZIP; nothing is unpacked or changed on disk).
- **Your files are never moved, renamed or changed.** History follows a file even when it's moved or renamed (it's recognised by its size and a fingerprint).
- **Series:** in a light novel folder, each folder inside is a series. Volume numbers are read however they're written: `LN 06`, `Vol. 2`, `Vol-2`, `vol.12`, `volume 9`, `Volume-11`, `(1) Volume A`, `[Red Rising 01]`… Shop and version tags such as `Premium`, `[Yen Press][Kobo]` and `(v5.0)` are dropped. Books elsewhere use the series in their own details (calibre and EPUB 3).
- **Editions:** folders like `Web Novel` and `Fan Translation` inside a series become editions with their own volume lists.
- **Same volume, two formats:** an EPUB and a PDF (or a ZIP copy) of the same volume show as one book. It opens the EPUB, and "Open as PDF" is on its page.
- **Cover grid** (Comfortable, Compact, Covers only) sized by the slider, + −, or Ctrl + wheel, plus a sortable **List**. A **Continue reading** strip sits at the top.
- Cover badges: progress line, series read count, favourite, rating, times read, PDF.
- **Book page:** cover, title, author, series and volume, description, length and reading time, formats, rating (half stars), favourite, tags, mark read or unread, mark previous volumes read, edit details, show in folder, details and reading history.
- **Series page:** every volume with ticks, progress, rating and formats; Continue; editions; mark read in bulk.
- **Filters**, each with its opposite: read, in progress, favourite, rated, in a series, light novels / books, PDF only, rating range, length, times read, read recently, tags, authors. Active filters show as pills.
- **Sorts**, all reversible: title, author, series, date added, last read, last or first finished, progress, rating, length, times read, time spent, random. **R** picks a random book.
- **Tags** with colours, on single books or many at once.
- Folders are watched, so new books appear by themselves. A quick rescan runs at start-up; unchanged books are skipped. If E: isn't connected, the library still opens and says so.

### Reader
- **Two pages side by side** when the window is wide (Auto), or always one or always two (D).
- **Lithium-style settings** (the Aa button): theme, font (Literata, Inter, Georgia, Palatino or the book's own), size, line spacing, margins, justify, the book's own styles, pages or scrolling, and page-turn animation.
- Click the left or right of the page to turn, the middle for the bars. Arrow keys, Page Up/Down, Space and the mouse wheel turn pages too.
- **Contents** (T), **bookmarks** (B), **search in the book** (/), and a progress slider.
- Bars show the chapter, page of the chapter, percentage, and time left in the chapter and the book. When hidden, a slim line shows the chapter page, percentage and clock.
- **Pictures** open full screen with zoom (scroll) and drag.
- **PDFs** show one or two pages fitted to the window, with the cover alone in two-page mode, and an optional **dark pages** setting.
- **End of the book:** rating, favourite, then **Next volume** (N). Volumes already read can be skipped (Settings).

### History and stats
- Every session: start, end, active reading time (idle time isn't counted), where reading started and stopped, and pages read.
- Every finish is recorded, so re-reads count up. First and last finish dates can be sorted.
- **Stats** for everything, light novels or books; all time, this year, this month or the last 30 days: books finished, reads, pages, hours, reading speed, streaks, books finished and pages and hours per month, a reading calendar, reading by hour, ratings, most-read authors and series, most re-read books, best-rated authors.
- A "page" is 1,500 letters of text, the same on the PC and the phone, so numbers match between devices.

## Keys

Press **K** in the app for the full list.

| Key | Does |
| --- | --- |
| K | Keyboard shortcuts |
| /, Ctrl+F | Search the library (in a book: search the book) |
| F, F11 | Full screen |
| H | Hide panels |
| M | Show or hide the sidebar |
| L | Log |
| S | Settings |
| R | Random book |
| Ctrl+A | Tick everything shown |
| + −, Ctrl+wheel | Bigger or smaller covers (in a book: text size) |
| Backspace, Esc | Back to the library |
| ← →, PgUp PgDn, Space | Previous / next page |
| Home, End | Start / end of the chapter |
| D | One or two pages |
| T | Contents |
| B | Bookmark this page |
| V | Favourite |
| N | Next volume |
| Esc | Close, innermost first |

## For the developer

- Flutter (Dart) for Windows now and Android in stage 2, sharing one codebase.
- `lib/core/`: database (SQLite), file-name parsing (`parse.dart`), reading EPUB/MOBI/ZIP details and covers (`books.dart`), the library scan, grouping, filters and sorts (`library.dart`), reading sessions (`reading.dart`), and the local server the reader page loads from (`server.dart`).
- `lib/ui/`: the shell, library, book and series pages, reader (`reader_page.dart`, with `pdf_view.dart` for PDFs), history, stats and settings.
- `assets/reader/`: the reading page. `sable.js` connects the app to [foliate-js](https://github.com/johnfactotum/foliate-js) (MIT), which lays out EPUB and MOBI books. The page is served from `127.0.0.1` only.
- PDFs are drawn with [pdfrx](https://pub.dev/packages/pdfrx) (PDFium).
- `flutter test` runs the unit tests (file-name parsing, reading books and ZIPs).
- `Sable.exe --selftest` (CI runs it on the built app) makes sample books, scans them, opens an EPUB and a PDF, turns pages, reads to the end, and takes screenshots of each screen into the data folder's `logs\`. Use `SABLE_ROOT` and `SABLE_DATA` to point it at test folders.
- GitHub Actions builds on every push to `main`: tests, build, self-test, then a release named after the version in `pubspec.yaml`. Raise the version for every release.
