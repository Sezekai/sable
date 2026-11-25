Sable 1.4.3

- Fixed: opening a book by double-clicking it could crash Sable. The book engine was being started before the window was drawn, which crashed the graphics driver. It now starts just after.
- Fixed: finding descriptions stopped with "Too many requests". Google Books limits free lookups, so Sable now asks Apple Books first (which has most light novels), then Google Books, then Open Library. A source that says it's busy is skipped for a while instead of stopping the job. Matching also checks the volume number, so Vol. 2 doesn't get Vol. 1's description.
- The keyboard shortcuts page lost its yellow underlines, and each section has a heading line and a divider.
- Starlight: Settings → Look → Stars sets how many stars there are (0% to 400%). The stars now also show behind the book in the reader, where the same option is in the reader's Settings.
- Scrolling moves half as far for each turn of the mouse wheel, in books and everywhere else.
- Scroll mode: with the top or bottom margin switched off, the margin still shows at the start and end of each chapter. Moving on to the next chapter now takes about five more turns of the wheel at the end, so it doesn't happen by accident.

PC: replace the `App` folder in `E:\Pictures\Sable\` with the new one. Phone: install `Sable-v1.4.3-android.apk` over the old one.
