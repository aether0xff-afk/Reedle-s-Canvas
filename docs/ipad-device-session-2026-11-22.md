# Windows laptop device investigation, 2026-11-22

Status: **blocked physical verification; AET-49 remains In Progress, 22/23 complete.**

## Source and scope

The work branch is `codex/ipad-device-fixes`, based on `codex/canvas-camera` commit
`b206f461065ac2f558de91f1144b30d4859e7882`. The laptop had an older device-lab kit
whose manifest names `53b7c3caaa3e9f7e9eca370656bb7bcf7e2175e6`; the source actually
running inside the iPad preview cannot yet be verified. No existing checkout was
modified. The retrieved snapshot was checked against every Git blob and the exact
base Git tree/commit. No base-branch update or force push is used.

## Evidence actually available

- The previous Prepare result identifies iPad14,8 / iPadOS 27.2.1 / build 24B156,
  but records `InstallationLookupFailed` for the assumed Playgrounds container.
- The previous Collect result resolves PID `0` for the fixed lab bundle. This
  proves neither an app crash nor the real preview bundle identity.
- The original current-branch Diagnose command timed out in USB discovery after
  30 seconds without a stack. An independent socket probe of the installed
  pymobiledevice3 Windows transport, `127.0.0.1:27015`, returned Windows access
  denial `10013`. The updated collector records `blocked_host_transport` promptly.
  Live USB connection, trust, current OS, installed app identity and process state
  therefore remain **unknown**, rather than being reported as an unplugged iPad.
- A read-only inspection of the laptop's existing Apple CrashReporter sync folder
  found 20 Jetsam reports dated October 20 through November 21. The November 21
  report matches iPad14,8 / 27.2.1 / 24B156 and lists `Swift Playground` as
  `suspended`, without a kill reason. No report dates to the November 22 workload;
  no Reedle/AppModule faulting stack is available. Apple **Image Playground**
  processes are unrelated to Swift Playgrounds and are excluded from triage.
- Native app UI access also failed to initialize in this session with
  `Managed execution requires a usable CODEX_CLI_PATH`. No device screen was
  observed or controlled, and no Pencil action was simulated or claimed.

Raw logs and copied reports are retained only under the ignored local
`.build/device-evidence/` directory. Originals were not erased. No raw report,
device name, serial, UDID, incident ID or private app inventory is published here.

## Confirmed tool failures and corrections

1. Collect used to return before even attempting app report retrieval if DVT PID
   lookup failed. AFC report copying now proceeds independently of DVT telemetry;
   scoped app discovery and explicit `--bundle-id` support replace an unconditional
   fixed PID lookup. Ambiguous canvas app identities require explicit selection.
2. Prepare now checks the installed Playgrounds identity before a source copy.
   Failed copying remains failed and is separate from runtime crash diagnosis.
3. Diagnose distinguishes host socket access denial from device trust failure and
   checks previously synced reports before trying live USB. Offline `analyze-crash`
   reads modern two-object IPS and legacy crash files without USB or changing the
   originals. Exception, termination, faulting thread and available frames are
   extracted. Jetsam presence/largest-process status alone is not a kill verdict.
4. Device Lab adds a synchronized, sampled phase journal around viewport paging,
   zoom/layout, offset and camera persistence. The first navigation and subsequent
   distant-region/scale-1 transitions are traced. All original display-link camera
   requests, 10,000 strokes, and 90/600-second schedules remain. Journal I/O
   overhead is included in measured cadence and must be reported with results.
5. Every workload gets a separate session report and journal, so a later battery
   run does not overwrite the earlier workload evidence. The latest `report.json`
   remains compatible with the exporter. Diagnostic/save failures retain a partial
   result rather than a completed test.

These are diagnostic/tool changes, **not an established fix for the reported app
crash**. No student storage semantics, AI layer permissions or production camera
behavior are changed. The optional navigation trace callback is nil in the normal
app. A final journal phase can narrow a failing boundary, but cannot replace an
exception/termination stack or prove a root cause.

## Physical scenario results for this session

| Scenario | Result | Measurement / limit |
| --- | --- | --- |
| 90-second automatic workload | Not executed on iPad | Earlier reported Unknown Crash remains unresolved |
| 600-second unplugged battery | Not executed on iPad | No eligible battery samples or battery drop |
| 10,000 strokes, rapid pan/zoom/distant regions | Not executed on iPad | Fixture and complete workload are retained in source |
| Student count/position/style and camera after process relaunch | Not verified on iPad | No current physical fingerprint/checkpoint evidence |
| Rotation, window resize and background return | Not verified on iPad | No current device lifecycle observations |
| App memory, frame cadence and device FPS | Not measured on iPad | No running app PID or current device report; old Jetsam pages are not app workload memory |
| Actual Apple Pencil responsiveness | Not observed | No quantitative latency or qualitative input claim |
| Network delay/failure while writing and saving | Not executed on iPad | Existing software regressions do not replace physical verification |

## Necessary next execution boundary

This session can build and test through the repository's GitHub Actions Mac
runner; that runner has no demonstrated route to this USB iPad and provides only
simulator evidence. The laptop's existing Python 3.12/pymobiledevice3 11.61.2
runtime is usable, but this agent's current execution permissions deny the Apple
USB transport. No accessible signed Mac installation path has been established.

Resume with an execution context that can reach the laptop's existing Apple USB
service, without disabling device security. The agent must then collect current
app/Jetsam reports and actual app identity, attempt delivery to the verified
Playgrounds Documents container, and confirm source provenance on the device.
File sharing success is source delivery, **not automatic Playgrounds build/run**.
If that service refuses access, establish a supported delivery/build route before
claiming a device update. No repeated user ZIP copying is part of this workflow.

Only after that boundary is available should physical actions be grouped: unlock
and trust if requested by the device, actual Pencil input, rotation/window changes,
background/relaunch, and unplugging for the battery run. Preserve all existing
test notes. Compare fingerprints and camera across a genuinely different process.
Review device evidence before updating AET-49.
