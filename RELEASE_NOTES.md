Sable 1.1.1

Fix
- Sable crashed at start-up (and once while browsing in 1.0.0). The crash was inside Flutter's built-in screen-reader support on Windows, which breaks when another program on the PC reads windows through Windows accessibility while Sable's library is updating. Sable now leaves that part out, so it can't crash there. The self-test now runs with accessibility switched on, to make sure.

Everything from 1.1.0 is included. Download `Sable-v1.1.1-windows.zip`, then replace the `App` folder in `E:\Pictures\Sable\` with the new one. Your library and settings are kept.
