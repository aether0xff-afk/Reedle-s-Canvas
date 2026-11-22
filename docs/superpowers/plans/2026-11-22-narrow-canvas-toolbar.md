# Narrow canvas toolbar

The remaining AET-49 software check includes split-view layouts. ContentView currently puts the title, stroke count, history buttons, four menus and Save in one 52-point row. Verify that these controls remain inside a 320-point content area and remain usable, then fix the layout if it fails.

Use a debug-only launch environment width to constrain the real app content for XCUITest. Check both 320 and 512 points, save screenshots, require primary buttons to remain within the content bounds with at least 44-point frames, and actually open the resource, practice and tutor menus and save the note. This checks the app's constrained layout, not iPadOS multitasking gestures or physical-device performance.

If a fix is needed, use one toolbar whose layout can change between one and two rows without duplicating TutorControls or its observation handlers. Keep controls accessible by name, use compact menu icons in narrow layouts, preserve all actions and ensure resizing cannot create a second tutor request handler.

- [x] Capture the existing constrained layout and reproduce any inaccessible controls.
- [x] Correct the toolbar while retaining the same control identities and actions.
- [x] Run the native/UI regression batch, inspect narrow screenshots and record the verified scope.

Group this verification automatically. Do not ask the user to repeat simulator tests. Physical Pencil latency, device frame rate and battery remain distinct measurements.

Run 44923114597 reproduced compressed controls: the 320-point menu frames were 15 points wide and the title/menu text wrapped vertically; at 512 points their frames were 29.5 by 20.5 points. Menus still opened, so this is a layout/touch-target defect rather than proof of total inaccessibility. The test recorded 16 size failures across the two widths. Both requested screenshots were retained and the 320-point image was inspected. Its artifact SHA-256 matched and all 1,546 ZIP members were checked for the provider credential.

Use one CanvasToolbar with AnyLayout and the same child controls across layouts, based on Apple's documented state-preservation behavior: https://developer.apple.com/documentation/SwiftUI/AnyLayout . The compact layout keeps named 44-point menu buttons, and the text-size-scaled breakpoint selects one or two rows. BAZE-served Codex reviewed the public source and reported no blocking findings. The full native batch remains the completion gate.

Run 44983717524 passed all 75 native unit and 5 UI cases with no failures or skips. Both constrained widths passed touch-target bounds and menu/save actions. The actual 320-point screenshot was inspected and retained in docs/assets/native-narrow-320.png. This completes the app layout check; actual iPadOS window gestures and physical-device metrics remain AET-49 gates.
