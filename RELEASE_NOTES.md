Sable 1.5.2

Library scrolling
- Found and fixed the cause of the jumpy, stop-start scrolling: every tile in the view was being rebuilt on every frame of a scroll (since 1.4.0's cover grid). With small covers that took far longer than a frame. In a test library of 1,200 books, a frame now takes about a tenth of the time.
- Scrolling lands on whole screen pixels, so covers no longer shimmer or "tear" as they move.
- While the wheel is scrolling, tiles passing under the pointer don't light up one after another (as in a web browser). Moving the mouse brings the highlight back.
- Titles are measured more cheaply, so new rows appear without a hitch.

Library
- Hovering over a book now grows its cover a touch everywhere (as in Continue reading), with a lighter tile and a thin outline in the accent gradient.
- The sort menu says what it is: a sort icon and "Sort: …".
- Buttons light up with an accent edge when you hover over them.
- Text and search boxes are a little taller, so text has room, and the Edit details window is wider.

Book and series pages
- The lines between the columns are as long as the taller of the two columns beside them (so the one by the cover ends at the Read button when the next column is short), and a little lighter.

History
- Every other row is a slightly different shade, and there's a card view (Rows / Cards beside the search).
- Continue has a button outline and lights up when hovered.
- Clear history moved to Settings → Reset → Reading history.

Covers
- Frame it: drag the picture to move it and use the mouse wheel (or pinch) to zoom in. No more buttons.

PC: replace the `App` folder in `E:\Pictures\Sable\` with the new one. Phone: install `Sable-v1.5.2-android.apk` over the old one.
