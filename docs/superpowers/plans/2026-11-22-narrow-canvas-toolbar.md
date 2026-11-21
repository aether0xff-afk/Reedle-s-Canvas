# Narrow canvas toolbar

The remaining AET-49 software check includes split-view layouts. ContentView currently puts the title, stroke count, history buttons, four menus and Save in one 52-point row. Verify that these controls remain inside a 320-point content area and remain usable, then fix the layout if it fails.

Use a debug-only launch environment width to constrain the real app content for XCUITest. Check both 320 and 512 points, save screenshots, require primary buttons to remain within the content bounds with at least 44-point frames, and actually open the resource, practice and tutor menus and save the note. This checks the app's constrained layout, not iPadOS multitasking gestures or physical-device performance.

If a fix is needed, use one toolbar whose layout can change between one and two rows without duplicating TutorControls or its observation handlers. Keep controls accessible by name, use compact menu icons in narrow layouts, preserve all actions and ensure resizing cannot create a second tutor request handler.

- [ ] Capture the existing constrained layout and reproduce any inaccessible controls.
- [ ] Correct the toolbar while retaining the same control identities and actions.
- [ ] Run the native/UI regression batch, inspect narrow screenshots and record the verified scope.

Group this verification automatically. Do not ask the user to repeat simulator tests. Physical Pencil latency, device frame rate and battery remain distinct measurements.
