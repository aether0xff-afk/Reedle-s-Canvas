# Usable app preview

The user explicitly asked to ignore testing and continue development. Do not request another device run or crash archive and do not run XCTest/pytest for this change. Keep the reported device-lab crash unresolved and AET-49 deferred. Original feature implementation is already 22/23 issues complete; this pass finishes the normal app's first-use presentation and source delivery.

- [x] Add passive empty-canvas guidance that never intercepts Pencil/finger input and disappears for ink, tutor marks, practice or imported PDFs.
- [x] Surface tutor scheduling/reading/drafting/proposal/error/mode states beside the canvas, with existing settings, cancel and question actions. Do not duplicate observation handlers or change automatic transmission consent.
- [x] Package the normal Swift Playground entry without device-lab sources or test buttons, using canonical committed source bytes and no credentials.
- [x] Add an opt-in app-preview build: compile and launch the normal app for an actual screenshot, without running tests or calling BAZE. Existing test workflows skip only this explicit preview commit marker.
- [x] Record the user's verification deferral and deliver the source preview and screenshot. Preserve the known crash as unresolved; no test-pass claim for this update.

Implementation choices: keep the current visual language, a compact status strip with one primary action and a light empty-state hint; use the existing TutorControls sheet and TutorAssistant methods. A build and normal-app screenshot are delivery checks, not a regression suite. No new product features or note formats are introduced.

Result: normal-app preview run 45112803317 built and rendered the actual app in light and dark appearances. No tests were executed. The source ZIP contains 32 files with no device-lab entry or provider credential, and canonical bytes match the built app source. A Windows server launcher was also added, using existing encrypted account settings and requiring TLS for non-loopback listeners; only its PowerShell syntax was parsed in this pass. AET-49 remains deferred, 22/23 items complete.
