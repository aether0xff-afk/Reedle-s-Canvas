# Native and live gateway verification

> **For agentic workers:** Use superpowers:executing-plans to implement this plan inline. The user has requested autonomous emulator testing and fewer test handoffs.

**Goal:** Finish AET-42 native animation verification and exercise AET-48 with actual PencilKit images and live BAZE responses in one Mac simulator batch.

**Architecture:** Native tests host the real SwiftUI renderer and compare snapshots with complete Core Graphics output. Each live Mac run generates a private RSA wrapping key and publishes only its public key. A credential sealed with RSA-OAEP-SHA256 to that exact run is decrypted into memory and passed only to a local gateway child. A simulator-only trusted loopback certificate permits the existing HTTPS/SSE app client to exercise live BAZE without putting the provider key in the app or logs.

**Tech stack:** XCTest, SwiftUI, PencilKit, GitHub Actions, RSA-OAEP-SHA256, the existing FastAPI gateway, simulator certificate trust.

**Spec:** Linear AET-42, AET-48, AET-49 and docs/ADR-0001-canvas-boundary.md.

## Constraints and review focus

- No BAZE key in GitHub configuration, build bundles, logs, screenshots or artifacts.
- Verify the public-key artifact belongs to the exact authored workflow run and commit before sealing the credential. Bind the encrypted packet to its run ID and SHA-256 public-key fingerprint.
- Allow at most six provider attempts. Stop the gateway and remove the private wrapping key, TLS key and app test resource in a finally block, including on failure.
- Keep the app's normal HTTPS/authentication contracts unchanged. A missing optional live fixture produces an explicit test skip; a configured but failing live gateway fails the test.
- A native simulator cannot establish physical Pencil latency, battery consumption or real-device frame rate. Keep AET-49 open for those measurements.
- Snapshot checks must prove partial path and glyph visibility, whole marks after cancellation, and unchanged student records after approval and undo.
- The live test must prove the wrong-answer target, actual hint, student correction, follow-up and durable restoration, not just HTTP success.

## Task 1 — Native reveal coverage

- [x] Add ReedlesCanvasTests/TutorAnimationTests.swift using a real UIHostingController.
- [ ] Run both new cases on the Mac simulator together with the regression suite.
- [ ] Inspect failures and saved screenshots; fix actual implementation issues if found.
- [ ] Record the proven AET-42 behavior in Linear and verification docs.

## Task 2 — Live native correction flow

- [ ] Add tools/run_live_ipad.py to prepare a per-run public key and run the local HTTPS/SSE gateway with a memory-only provider credential.
- [ ] Add an optional, ignored LiveGateway.json test resource and ReedlesCanvasTests/TutorLiveGatewayTests.swift.
- [ ] Verify sealed credential decryption, run/key binding, ciphertext tampering, invalid tokens and failure cleanup locally.
- [ ] Run the existing native capture/client/approval/storage path against live BAZE for 2+2=5 and 2+2=4.
- [ ] Verify the actual responses, screenshots, persisted layers and student records.
- [ ] Remove the encrypted delivery file from the active branch, verify cleanup, and document exact coverage and remaining physical-device gaps.

## Execution rulings

Ruling: Replace the planned OIDC tunnel with a per-run sealed credential — both Cloudflare bootstrap HTTPS and localhost.run SSH timed out from this PC. The OIDC verifier passed 15 local checks, but no external tunnel became available. The replacement uses the user's authorized BAZE/Mac test route, encrypts delivery to a verified ephemeral runner key, and keeps the plaintext out of repository files and the iPad app. The encrypted packet is publicly retrievable during delivery, so runner-key provenance and end-of-run private-key deletion are required checks.

Ruling: Count snapshot regions by cropping the CGImage before reading pixels — this avoids a vertical bitmap coordinate conversion and includes an asymmetric calibration marker to prove screen-region alignment.
