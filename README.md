# Sable

A library and reader for books and light novels, built to feel like Lithium: clean, compact and quick, with an OLED black or Starlight look and gradient accents. Books and light novels live in one library, with series, history, stats, ratings, favourites and tags.

There's a Windows app and an Android app. The phone keeps the whole library (covers, history, stats) and syncs with the PC over your home WiFi; books you pick are downloaded to it for reading anywhere.

## Install and update

1. Download `Sable-vX.Y.Z-windows.zip` from the latest [release](../../releases).
2. Unzip it to `E:\Pictures\`. You get `E:\Pictures\Sable\App\Sable.exe`.
3. Run `Sable.exe`. No installer and no admin rights are needed.

EPUB and MOBI books are shown with Microsoft Edge WebView2, which comes with Windows 11. If it's ever missing, Sable says so and how to get it.

**Updating:** replace the `App` folder with the new one. Your library, history, settings and covers are kept, because they live outside it.

### The phone app (Android)

1. Download `Sable-vX.Y.Z-android.apk` from the same release onto the phone and open it (allow installing from your browser or files app if Android asks).
2. On the PC: Sable → Settings → Phone shows a 6-digit pairing code. The first time, Windows asks whether Sable can use the network: allow it for **private** networks (your home WiFi should be set as a private network).
3. On the phone: Settings → Connection → Connect to your PC. It finds the PC on the same WiFi (or type the PC's address shown on the PC), then type the code.

The phone then brings in the library, all reading records and every cover. **Updating:** install the new APK over the old one; everything on the phone is kept.

**What syncs:** where you are in each book, reading sessions, finished books and read marks, ratings, favourites, tags and bookmarks — both ways. Sync happens when the app opens, when it comes back to the front, after closing a book and every 5 minutes, whenever the PC can be reached (Sable has to be open on the PC). Changes made away from home wait on the phone and go across at the next sync. If both sides changed the same thing, the latest change wins; reading sessions and finishes from both sides are all kept.

**Downloads:** nothing is downloaded by itself. Download a book from its page, or a whole series (all, or only the unread volumes) from the series page, or tick several in the library (long-press) and tap Download. The Downloads tab shows each download with a progress bar, percentage, speed, time taken and time left, and can pause, resume or cancel. A book that isn't downloaded can still be opened while at home: it's read straight from the PC. Downloads never change anything on the PC.

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
| Phone pairing (code, paired phones) | `%LOCALAPPDATA%\Sable\sync.json` |
| On the phone: library, history, pairing | the app's own storage (removed if the app is uninstalled) |
| On the phone: covers and downloaded books | `Android/data/com.sezekai.sable/files/Cache/` |

Settings → Storage shows each place with its size, and can open, move or clear it.

## Features

### Library
- **One library** for books and light novels. Each folder is marked Books or Light novels, and can be marked as a **Collection** (downloaded packs). **Collections shown / hidden** in the toolbar hides those books in one click.
- Default folders: `E:\Documents\LIGHT NOVELS` (light novels), `E:\Documents\BOOKS`, `E:\Documents\BOOKS I OWN` and `E:\Documents\BOOK Collections` (a collection).
- Reads **EPUB, PDF, MOBI and AZW3**, also when they're inside a **ZIP** (read straight from the ZIP; nothing is unpacked or changed on disk).
- **Your files are never moved, renamed or changed.** History follows a file even when it's moved or renamed (it's recognised by its size and a fingerprint).
- **Series:** in a light novel folder, each folder inside is a series. Volume numbers are read however they're written: `LN 06`, `Vol. 2`, `Vol-2`, `vol.12`, `volume 9`, `Volume-11`, `(1) Volume A`, `[Red Rising 01]`… Shop and version tags such as `Premium`, `[Yen Press][Kobo]` and `(v5.0)` are dropped. Books elsewhere use the series in their own details (calibre and EPUB 3).
- **Editions:** folders like `Web Novel` and `Fan Translation` inside a series become editions with their own volume lists.
- **One entry per book:** an EPUB and a PDF (or other versions) of the same book show once, as the EPUB, with "Read the PDF" and the other copies on its page. Progress is shared between them and you choose the default copy. Copies Sable doesn't spot can be **combined** by hand (and separated again).
- **Make a series** from any ticked books, then set its name, order, description and cover.
- **Descriptions and covers:** missing descriptions are looked up online (Google Books, then Open Library) from Settings, a book or series page, or for ticked books. Any description can be written by hand, and any cover changed by pasting an image (or image link), dragging one in, or choosing a file.
- **Default ebook app on Windows** (Settings → Opening ebooks): double-clicking an EPUB, MOBI or AZW3 opens it in Sable. Books outside the library are tracked in History and resume where you left off; if they're added later, their progress is already there.
- **Cover grid** (Comfortable, Compact, Covers only) sized by the slider, + −, or Ctrl + wheel, plus a sortable **List**. A **Continue reading** strip sits at the top.
- Covers are 1.5 times as tall as they're wide everywhere. Titles use two lines when they need to (the author shows when the title fits on one).
- Cover badges: progress line, series read count and PDF (small, in the corner), favourite, rating, times read.
- **Book page:** cover, title, author, series and volume, description, length and reading time, formats, rating (half stars), favourite, tags, mark read or unread, mark previous volumes read, edit details, show in folder, details and reading history.
- **Series page:** every volume with ticks, progress, rating and formats; Continue; editions; mark read in bulk.
- **Filters**, each with its opposite: read, in progress, favourite, rated, in a series, light novels / books, PDF only, rating range, length, times read, read recently, tags, authors. Active filters show as pills.
- **Sorts**, all reversible: title, author, series, date added, last read, last or first finished, progress, rating, length, times read, time spent, random. **R** picks a random book.
- **Tags** with colours, on single books or many at once.
- Folders are watched, so new books appear by themselves. A quick rescan runs at start-up; unchanged books are skipped. If E: isn't connected, the library still opens and says so.

### Reader
- **Two pages side by side** when the window is wide (Auto), or always one or always two (D).
- **Text and spacing** (A): font (Literata, PT Serif, Domine, Arbutus Slab, Georgia, Palatino, Inter, Segoe UI, Open Sans, Lato or the book's own), text size, line, word and paragraph spacing, paragraph indents, side and top/bottom margins in %. Every value has − and + buttons (tap the number to type one) in steps of .5 or 5%.
- **Settings** (S): theme, pages at once, text colour, alignment (left, centre, right, justify), **same top line** (text always starts on the same line, even after a heading or a new chapter), turning, animation, controls and mouse.
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

- Flutter (Dart) for Windows and Android, sharing one codebase. `isPhone` (`lib/core/platform.dart`) switches the phone's screens; `SABLE_PHONE=1` runs the phone app on a computer for testing.
- Sync: `lib/core/sync_server.dart` (PC: a small HTTP server on port 47650 that only answers paired phones, plus discovery on UDP 47651), `sync_client.dart` (phone), `sync_protocol.dart` (the changes the phone sends and how the PC applies them, and the snapshot it sends back), `downloads.dart` (phone downloads).
- `lib/core/`: database (SQLite), file-name parsing (`parse.dart`), reading EPUB/MOBI/ZIP details and covers (`books.dart`), the library scan, grouping, filters and sorts (`library.dart`), reading sessions (`reading.dart`), and the local server the reader page loads from (`server.dart`).
- `lib/ui/`: the shell, library, book and series pages, reader (`reader_page.dart`, with `pdf_view.dart` for PDFs), history, stats and settings.
- `assets/reader/`: the reading page. `sable.js` connects the app to [foliate-js](https://github.com/johnfactotum/foliate-js) (MIT), which lays out EPUB and MOBI books. The page is served from `127.0.0.1` only.
- PDFs are drawn with [pdfrx](https://pub.dev/packages/pdfrx) (PDFium).
- `flutter test` runs the unit tests (file-name parsing, reading books and ZIPs).
- `Sable.exe --selftest` (CI runs it on the built app) makes sample books, scans them, opens an EPUB and a PDF, turns pages, reads to the end, and takes screenshots of each screen into the data folder's `logs\`. Use `SABLE_ROOT` and `SABLE_DATA` to point it at test folders.
- GitHub Actions builds on every push to `main`: tests, build, self-test, then a release named after the version in `pubspec.yaml`. Raise the version for every release.
