# Native fast pan and pinch verification

The completion audit found that the camera's mathematics and 10,000-stroke paging workload were tested, but the recorded UI cases did not synthesize fast pan/pinch gestures. AET-49 explicitly requests that path. Add one real-app UI case, reusing the existing CanvasToolbarUITests selection so the entire model/native regression need not be repeated for accessibility identifiers and test-only coverage.

Open the isolated seven-stroke example, apply its tutor overlay, remember the camera, and collect a settled native canvas image. Perform a native pinch out and verify that visible ink becomes smaller. Run a pinch in and fast swipes on both axes, then return to the remembered position, save, relaunch and compare ink bounds and pixel counts. Check seven student strokes remain. Attach the actual images and numerical evidence. Do not assume XCTest produces an exact requested velocity; inspect the resulting geometry.

The app changes only add invisible accessibility identifiers for finding the canvas and its View menu. Wait for equal consecutive rendered measurements rather than sampling an animated glyph at an arbitrary intermediate wall-clock time. Exclude the system Pencil picker from measurements. This checks native gesture routing, rendering and persistence, not hardware Pencil latency, device FPS or battery.

- [x] Audit existing tests and identify the missing real gesture path.
- [x] Add the native UI case and stable image measurement.
- [ ] Run the focused UI class on Mac, inspect any failures and actual attachments.
- [ ] Record the covered scope and retain physical-device gates.

Apple documents pinch requests as best-effort: https://developer.apple.com/documentation/xcuiautomation/xcuielement/pinch(withscale:velocity:)
