Sable 1.4.4

- Fixed: an occasional crash when opening a book. The crash reports point at the graphics driver, at the moment the book engine starts while the window lay across both screens. Sable's window now always opens on one screen, which stops that from happening.
- Fixed: Sable could crash while closing (inside the book engine's own shutdown). It now ends straight away once everything is saved, and a close requested twice is only handled once.
- Sable opens maximised on the screen you open it from (the one the mouse pointer is on), instead of a window across both screens.
- The reader has the same top bar as the library: drag it to move the window, double-click it to maximise or restore, and minimise, maximise and close buttons on the right. It shows the book's title, and is hidden in full screen.

PC: replace the `App` folder in `E:\Pictures\Sable\` with the new one. Phone: install `Sable-v1.4.4-android.apk` over the old one.
