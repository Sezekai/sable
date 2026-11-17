Sable 1.1.2

Brought over from Shiori, which had the same start-up crash:
- The log is written to disk line by line, so its last lines survive if Sable ever stops unexpectedly. (In 1.0.0, the end of the log was lost.)
- After an unexpected stop, the next run copies the end of the previous run's log into its own log, next to the crash report.
- A heartbeat line every 30 seconds records memory use and what Sable was doing.
- Safe mode (after two unexpected stops in a row) also pauses background cover making, not just folder watching.
- Files are saved under a unique temporary name first, so two parts of Sable saving the same cover at once can't clash.
- The self-test now resizes the library grid quickly with accessibility on, which is exactly what used to crash.

Includes the 1.1.1 crash fix and everything from 1.1.0. Download `Sable-v1.1.2-windows.zip`, then replace the `App` folder in `E:\Pictures\Sable\` with the new one. Your library and settings are kept.
