# Usable app preview

The user explicitly asked to ignore testing and continue development. Do not request another device run or crash archive and do not run XCTest/pytest for this change. Keep the reported device-lab crash unresolved and AET-49 deferred. Original feature implementation is already 22/23 issues complete; this pass finishes the normal app's first-use presentation and source delivery.

- [ ] Add passive empty-canvas guidance that never intercepts Pencil/finger input and disappears for ink, tutor marks, practice or imported PDFs.
- [ ] Surface tutor scheduling/reading/drafting/proposal/error/mode states beside the canvas, with existing settings, cancel and question actions. Do not duplicate observation handlers or change automatic transmission consent.
- [ ] Package the normal Swift Playground entry without device-lab sources or test buttons, using canonical committed source bytes and no credentials.
- [ ] Add an opt-in app-preview build: compile and launch the normal app for an actual screenshot, without running tests or calling BAZE. Existing test workflows skip only this explicit preview commit marker.
- [ ] Record the user's verification deferral and deliver the source preview and screenshot. Preserve the known crash as unresolved; no test-pass claim for this update.

Implementation choices: keep the current visual language, a compact status strip with one primary action and a light empty-state hint; use the existing TutorControls sheet and TutorAssistant methods. A build and normal-app screenshot are delivery checks, not a regression suite. No new product features or note formats are introduced.
