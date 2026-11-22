# Physical Device Lab JSON writer crash

Status: **failing boundary established from a physical stack; corrective patch and
physical revalidation are separate. AET-49 remains In Progress, 22/23 complete.**

## Device evidence

The supplied `ReedleDeviceLab-2026-11-22-202124.ips` identifies iPad14,8,
iPadOS 27.2.1 (24B156), foreground Device Lab 1.0 (1), with faulting thread 0.
It records `EXC_CRASH / SIGABRT`, termination namespace `SIGNAL`, code 6,
`Abort trap: 6`. The last exception backtrace and the main-thread stack agree:

```text
DeviceLabController.start(seconds:)
DeviceLabController.writeProgress(completed:reason:)
DeviceLabController.saveReport(_:)
+[NSJSONSerialization dataWithJSONObject:options:error:]
_writeJSONObject / _writeJSONValue
objc_exception_throw -> abort
```

This event fails while writing the initial report synchronously from the Start
button, before the display-link camera workload. It therefore provides evidence
against attributing **this event** to the nine-second camera transition. It does
not establish that every previously reported Unknown Crash had the same cause.
App launch to capture is about 11.8 seconds, including preparation and operator
interaction; this is not the workload duration.

The actual preview uses a dynamically generated bundle of the form
`swift-playgrounds-dev-run.swift-playgrounds-app.<redacted>.501.ReedleDeviceLab`,
rather than the assumed standalone lab bundle. Its exact source commit is not
recorded in the IPS and remains unknown. The identifier, container paths, device
identifiers, incident IDs, and raw registers are excluded from the public report.

The separately supplied Jetsam file is dated 13:54:27 KST, while the app crash
capture is 20:21:20 KST. It has no Reedle/DeviceLab/AppModule/Swift Playground
process entry and does not demonstrate a memory kill of this workload. A crash
report's virtual-address-space summary is not physical footprint or peak app RAM.
No new physical frame, workload memory, battery-drop or Pencil-latency metric is
claimed from either attachment. The supplied originals are retained unchanged and
are not included in Git or the packaged source.

## Confirmed boundary and remaining uncertainty

The unsafe diagnostic writer calls `JSONSerialization.data(withJSONObject:)`
with dynamic `[String: Any]` dictionaries. Invalid Foundation JSON input can raise
an Objective-C exception rather than a catchable Swift `Error`, so surrounding
`do/catch` does not protect this boundary. Apple's documentation explicitly calls
for checking input validity before that API:
[JSONSerialization writer](https://developer.apple.com/documentation/foundation/jsonserialization/data(withjsonobject:options:)).

The stack establishes JSON-writing failure but **does not identify the particular
invalid field, object type, or value**. There is no exception-reason string naming
that field in the supplied report. Non-finite numbers and unsupported boxed
values are regression inputs, not asserted facts about the user's measurement.

## Corrective change

`DeviceLabJSON` converts diagnostic dictionaries into an explicit `Encodable`
value tree and uses `JSONEncoder`. It handles nulls, arrays, string-keyed objects,
booleans, CGFloat/finite floating-point values and full-width signed/unsigned
integers. Boxed optionals, unsupported types and non-finite numbers produce a
catchable error with an exact field path; they are not changed into zero or
silently omitted. This removes the observed Objective-C JSON writer from report,
journal, checkpoint and export serialization. See also Apple's
[JSONEncoder error behavior](https://developer.apple.com/documentation/foundation/jsonencoder/encode(_:)).

An encoding failure preserves the last valid report and writes
`serialization-error.txt` using plain UTF-8, including stage, source version and
field path/type. It does not recursively call the failing writer. The initial
failure status remains visible to the operator. Invalid telemetry never becomes
a passed or completed workload.

No student-note, AI-layer, camera, fixture-count or workload-duration behavior is
changed. The full 10,000 strokes and original 90/600-second camera workload remain.
The collector now retains `lastExceptionBacktrace` in addition to the abort thread
and understands IPS `modelCode` metadata.

## Verification scope

New native regressions cover booleans versus numeric one, UInt64.max/Int64.min,
CGFloat camera values, nulls and empty-frame metrics; non-finite values, Date and
boxed nil produce catchable field-path errors. A report-write regression asserts
that failure preserves the last report bytes and persists the plain-text error.
The complete 90-second workload was rerun with the changed writer in
[CI 45018193038](https://github.com/aether0xff-afk/Reedle-s-Canvas/actions/runs/45018193038).
Source `c1b4346378119097752bd2d79a1c03326cc0a965` passed all 17 selected native
cases (8 Device Lab, 9 camera), zero failures/skips, on iPad mini (A17 Pro),
iPadOS 26.5 Simulator / Xcode 26.6. The 90-second case's total test wall time was
92.414 seconds, including setup and verification; this is not physical workload
timing. The Python diagnostic suite passed 28 cases. The first corrective build
had a type-name collision with the FileDocument export type; that compile error
was corrected before these successful tests.

The prepared device source is `Reedle-DeviceLab-c1b4346.swiftpm.zip`, 90,018 bytes,
SHA-256 `d51b40432f99d951bfdc3f3a318c5f8b365048ffbed12f621d698f9b3cd6e785`.
Its generated build identity matches that source commit. The isolated lab header
displays the first 12 commit characters so the operator can verify the installed
source before testing. The user chose to handle source insertion; no source
transfer or device build/run is claimed. Raw device logs are excluded from this
package.

Physical acceptance still requires running the corrected source on the same iPad:
first confirm that the initial report succeeds, then complete the full workload
and inspect any serialization-error field if present. The 600-second unplugged
run, genuine process relaunch, real Pencil input, lifecycle/window tests and
network-failure checks remain pending. Simulator success cannot close AET-49.
