# Dictation indicator visual check

> Historical report: `DictationIndicatorHarness` was retired in coo:1071. Its commands below
> describe the original run. See [maintained tools and coverage](../../../Tools/README.md).

Rendered from `Tools/DictationIndicatorHarness` with SwiftUI `ImageRenderer` at 2× scale on macOS 27. These are the actual `DictationIndicatorView` states; the harness does not start another Scribe instance.

| State | Screenshot |
| --- | --- |
| Listening, hold | [listening-hold.png](listening-hold.png) |
| Listening, double tap | [listening-toggle.png](listening-toggle.png) |
| Transcribing after 800 ms | [transcribing.png](transcribing.png) |
| Inserted | [inserted.png](inserted.png) |
| Copied | [copied.png](copied.png) |
| Warming | [warming.png](warming.png) |
| Error | [error.png](error.png) |

The harness found two active displays: `(0, 0, 2056, 1336)` and `(-2240, -1110, 2240, 1260)` points. The indicator uses the AX caret's point to select the display, including when the caret width is zero, and clamps the panel to that display's visible frame. The panel declares `.canJoinAllSpaces` and `.fullScreenAuxiliary`. A live full-screen insertion was not exercised because the running Scribe instance is a different build and this objective does not restart it.
