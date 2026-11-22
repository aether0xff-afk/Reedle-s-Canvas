# Laptop Device Lab Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline. Steps use checkbox syntax for tracking.

**Goal:** Deliver a Windows laptop kit that runs the current canvas source on the user's iPad and returns honest physical-device evidence.

**Architecture:** An isolated Swift Playground lab measures the current native canvas; a pinned Windows Python runner collects local USB diagnostics, optional DVT samples and exported lab reports. Package both with one launcher and a short operator guide.

**Tech Stack:** SwiftUI/PencilKit/CADisplayLink, Python 3.12, pymobiledevice3 11.61.2, PowerShell 5.1+, uv 0.13.9.

**Spec:** `docs/superpowers/specs/2026-11-22-laptop-device-lab-design.md`

## Global Constraints

- Use this checkout on codex/canvas-camera; preserve pre-existing untracked OpenCode files.
- No provider credentials, Apple login, arbitrary app collection, automatic device selection or global execution-policy changes.
- Source and result provenance must be explicit; simulator data cannot close the physical-device gate.
- Existing 80-case live/native evidence remains historical evidence; new checks validate the lab, not unexecuted hardware results.

## Review Focus

- Several USB devices: require explicit UDID selection.
- USB charging: battery drain remains inconclusive.
- DVT unsupported, disconnect or empty stream: retain diagnostics and mark missing evidence.
- Swift Playgrounds cannot expose the runtime app container: support manual JSON export/import.
- App background/scene resize: retain interruption and size events rather than treating them as smooth foreground frames.

## Tasks

### 1. Windows collector and evidence grading

Files: `tools/device_lab/runner.py`, `tools/device_lab/pyproject.toml`, `tools/device_lab/uv.lock`, `tools/test_device_lab.py`.

- [ ] Write offline tests for device ambiguity, failed/empty stream, simulator rejection, charging battery, lab provenance and safe result import.
- [ ] Observe the missing implementation fail, then implement command execution, JSON/JSONL collection, bounded shutdown, local reports and ZIP manifest.
- [ ] Verify pinned CLI syntax against the installed package, then run the grouped offline checks.

### 2. Isolated iPad workload and metrics

Files: `ReedlesCanvas/DeviceLabMetrics.swift`, `ReedlesCanvas/DeviceLabView.swift`, `ReedlesCanvasTests/DeviceLabTests.swift`, `tools/playgrounds/DeviceLabApp.swift`.

- [ ] Add metrics tests for real interval quantiles, missing battery and interrupted runs; controller check verifies note isolation, 10,000-stroke persistence and report serialization.
- [ ] Implement the lab using existing DrawingDocument, CanvasNavigation and ContentView. Preserve normal app entry and source authority.
- [ ] Run one focused Mac native batch; distinguish test coverage from physical measurements.

### 3. Transfer package and handoff

Files: `tools/package_device_lab.py`, `tools/device_lab/Start-Reedle-Tests.ps1`, `tools/device_lab/Run-Tests.cmd`, `docs/laptop-device-tests.md`, `.github/workflows/ios-build.yml`.

- [ ] Bundle locked runner, hash-verified local uv bootstrap, current Swift sources and standalone lab entry.
- [ ] Verify package CRC, hashes, source completeness, launcher parsing and lack of credentials; exercise no-device and imported-result paths locally.
- [ ] Review the whole change, commit/publish the branch, and deliver the actual kit with precise one-time setup and result-return steps.
- [ ] Record AET-49 as awaiting real laptop/iPad evidence, not complete.
