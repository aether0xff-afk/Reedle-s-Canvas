# Physical device crash investigation

The user reports both lab buttons crash after about nine seconds or later, with an empty console. The returned 1,185-byte ZIP contains only USB prepare/source-transfer logs; its hashes and CRC were checked. It identifies iPad14,8/iPadOS 27.2.1 and a source-copy InstallationLookupFailed. No app backtrace or app measurement report is present. Do not conflate source-copy failure with the workload crash.

- [x] Trace the common lab path: the 90-second workload starts camera changes after nine seconds; the 600-second workload after sixty seconds. Timing is consistent with movement, not proof of a root cause.
- [x] Add a scoped, bounded collector for existing app/Jetsam crash records without rerunning or erasing device reports; retain errors and selected app identities.
- [x] Reproduce missing collector/source-transfer reporting behavior with three failed regressions, then pass all sixteen collector checks.
- [x] Run a real 90-second native simulator workload to cover scale values and transitions missed by the previous 0.5-second case. This cannot prove the iPadOS 27.2.1 crash fixed.
- [ ] Deliver a separate diagnostic ZIP and obtain the existing device backtrace before changing app behavior.
- [ ] Use that stack/termination evidence to reproduce and fix the actual failing boundary, then run one grouped verification and return an updated app source package.

No app fix has been applied on a guess. AET-49 remains In Progress, 22/23 issues complete. Uploaded device logs stay outside Git.

Run 44997226681 passed all four selected native cases with zero failures/skips. The full workload recorded 90.0138 seconds, 4,017 applied camera requests, unchanged 10,000 stroke records, and 123,460,096 bytes peak simulator process footprint. All 16 collector regressions and the server/contract checks also passed. The artifact SHA-256 matched and all 55 ZIP members were checked for provider-key absence. This run uses iPadOS 26.5 Simulator, whereas the reported physical crash is on iPadOS 27.2.1; it did not reproduce the physical crash. The diagnostic ZIP was delivered and the device backtrace remains outstanding.
