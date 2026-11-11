# Phone LiDAR — Implementation plan

| | |
|---|---|
| Document | Process, model delegation, review protocol, phased checklists, change log |
| State | v1 feature set on `main` (`1cf693e`, build #23). P8 process alignment on branch `process-alignment`: M1 review cycles 1–3 converged (no new Critical/High/Medium); the final review and its re-reviews (Opus 5.5 / max) run until one yields no new findings; every finding so far is fixed or deferred to P10 with a reason. Findings, counts and CI runs: [reviews/2026-11-10-M1.md](reviews/2026-11-10-M1.md). Not yet merged to `main`. |
| Date | 2026-11-10 |
| Related | [requirements.md](requirements.md), [design.md](design.md), [../CLAUDE.md](../CLAUDE.md), [reviews/](reviews/) |

Agents keep this file current: tick a task when its PR is merged, add a change-log entry for every merged PR or revision, and add newly found work to P10.

---

## 1. Overview

| Phase | Content | State |
|---|---|---|
| P0 | Bootstrap: repository, CI build, folder layout | Done (PR #1, build #5) |
| P1 | Room, Equipment (mesh), Object capture, viewer, library | Done (initial upload, PR #1) |
| P2 | Line scan core: capture, speed, recording, playback, topographic map | Done (PR #2, build #8) |
| P3 | Playback touch probe | Done (PR #3, #4, build #12) |
| P4 | Bubble level and surface tilt | Done (PR #5, build #14) |
| P5 | Baseline (flat-surface) calibration and height mode | Done (PR #6, build #17) |
| P6 | Local (zone) speeds | Done (PR #7, build #19) |
| P7 | Topographic replay | Done (PR #8, build #23) |
| P8 | Process alignment: docs, CLAUDE.md, unit tests in CI, milestone M1 reviews and fixes, final review | In progress (cycles 1–3, final review and re-reviews; unmerged) |
| P9 | On-device validation on the iPhone 17 Pro Max | Not started |
| P10 | Backlog | Open |

Build numbers are GitHub Actions run numbers of the `Build iOS app` workflow on `main` (artifact `PhoneLidar-unsigned-ipa-<n>`).

## 2. Model and reasoning matrix

| Task type | Model | Reasoning |
|---|---|---|
| Requirements, architecture, design, implementation planning, major design changes | Opus 5.5 | max |
| Final review (implementation complete; also at milestones when the plan calls for it) | Opus 5.5 | max |
| Milestone review cycles (correctness, defects, security, performance, concurrency) | Opus 5.5 | high |
| Implementation in capture / signal-processing / concurrency / file-format code (`PhoneLidar/Line/*` pipeline, `SpeedEstimator`, `Baseline`, `TopoMapBuilder`, `TopoGridFile`, `TopoReplayData/Model`, `LineRecording`) | Opus 5.5 | high |
| Implementation of UI and routine features (SwiftUI views, settings, sharing, wiring, Room/Mesh/Object screens) | Sonnet 5.5 | high |
| Unit tests | Sonnet 5.5 | high |
| CI log triage and compile-error fixes | Sonnet 5.5 | medium |
| Docs upkeep (build guide, change log, checklists, CLAUDE.md, REVISIONS.md) | Sonnet 5.5 | medium |
| Mechanical work (renames, formatting, file inventory, searches) | Haiku 5.5 | low |

- The agent that did a task self-reviews it at the same model and level before committing.
- Milestone and final reviews are done by a fresh agent that did not write the code.
- A task touching both capture code and UI takes the higher assignment (Opus 5.5 / high).
- Every checklist line below ends with its assignment `(Model / level)`.

## 3. Per-task workflow

1. **Pick** an unchecked task; the orchestrator delegates it at the model/level on its line.
2. **Branch** from the latest `main`: `git fetch origin && git switch -c <short-kebab-topic> origin/main`. One topic per branch.
3. **Implement** in small commits at each verified unit of work. Imperative subject line (≤ 72 characters), body explaining why, and the required trailer (see [CLAUDE.md](../CLAUDE.md)).
4. **Self-review** against the checklist in §4 at the same model/level; fix what it finds before pushing.
5. **CI**: push the branch, run `Build iOS app` (dispatch or PR). Both the app build and the unit tests must be green with 0 warnings. Fix and repeat.
6. **PR** into `main`: summary, requirement IDs (FR-/NFR-), review finding IDs fixed, test evidence (CI run number), self-review notes. Agents never push to `main`; the merge happens on GitHub.
7. **After merge**: tick the task here and add a change-log entry (date, build number of the merge build, PR, summary); update [requirements.md](requirements.md) traceability/status and [design.md](design.md) if behaviour or formats changed; note user-visible changes for the build guide; the orchestrator updates `REVISIONS.md` and the owner's local copy; update `CLAUDE.md` when a convention or command changed.

## 4. Self-review checklist

Run before every commit that completes a unit of work. Record anything deliberately left open in the PR body.

- [ ] **Correctness** — behaviour matches the requirement IDs and design sections; units (mm, mm/s, s, degrees; metres only in Room/Mesh/Object) and sign conventions ([design §6.1](design.md#61-coordinate-conventions)) are right; formulas checked by hand on one example.
- [ ] **Defects and edge cases** — empty or 1-frame recordings, missing/truncated/corrupt files, no texture lock, no baseline vs baseline, both travel directions, recordings from older builds (optional fields absent), division by zero, NaN/∞ (note: `JSONEncoder` throws on non-finite numbers), integer overflow (e.g. rows × columns), index bounds.
- [ ] **Concurrency** — each piece of state has one owner (main actor, `phonelidar.line.data`, `phonelidar.line.session`, detached task); nothing touches UI or `@Observable` state off the main actor; no blocking work on the main actor or in the display-link tick; tasks check cancellation after `await`; display links, observers and timers are torn down.
- [ ] **Memory and resources** — no unbounded growth during capture; per-frame allocations kept small; file handles closed; `CVPixelBuffer` locks balanced; large data processed off the main thread.
- [ ] **Data integrity** — atomic writes for metadata; captured data is never deleted on failure; on-disk formats stay backward compatible (new `Codable` fields optional; binary format changes bump the version and keep the old reader); frame counts stay in lock-step.
- [ ] **Error handling** — failures reach the user with a clear message; no `try?` on paths that write or read measurement data unless the fallback is documented.
- [ ] **Security and privacy** — no secrets, Apple IDs, keys, personal data, plant imagery or scan data committed; no network code; new permissions have purpose strings; workflow changes keep least privilege.
- [ ] **Build hygiene** — 0 warnings in the CI summary; no force unwraps on file or device data; no debug `print`.
- [ ] **Tests** — unit tests added or updated for changed pure logic; CI `unit-tests` job green.
- [ ] **UI** — portrait (replay excepted), readable on dark panels, touch targets usable with gloves, accessibility labels on icon buttons.
- [ ] **Docs** — requirements/design/traceability, this plan (checkbox, change log), build-guide notes and `CLAUDE.md` updated as needed.

## 5. Review protocol

Severity:
- **Critical** — crash, data loss/corruption, security or privacy exposure, wrong measurement written to output files.
- **High** — wrong results in common use, likely thread-safety bug, resource/memory leak during capture, CI/build break.
- **Medium** — wrong behaviour in edge cases, missing user-visible error handling, performance problem that affects use.
- **Low** — maintainability, naming, duplication, minor UX polish.

Cycle: review → triage → fix → CI green → re-review of the changed code and anything it touches → repeat **until a review yields no new findings** (owner's rule). "New" means any finding, of any severity, that is not already fixed or recorded in the P10 backlog with a reason. Critical/High/Medium are always fixed; a Low is fixed or, when the fix is risky or large, deferred to P10 with a reason, and the next review checks the fixes.

- Milestone review cycles: fresh agents, Opus 5.5 / high, split by area when large.
- Final review: Opus 5.5 / max, after the milestone cycles; if it yields findings, they are fixed and re-reviewed at Opus 5.5 / max until a review yields no new findings.
- Every branch merged into an integration branch or `main` has a green CI run at its head commit first.
- Each cycle is recorded in `docs/reviews/<YYYY-MM-DD>-<milestone>.md` with finding ID, severity, file:line, summary, fix branch/PR, status.

## 6. Phased checklists

### Completed phases (P0–P7)

Reconstructed from git history, CI runs and `REVISIONS.md`. Commits from PR #1 to PR #8 carry the `Co-Authored-By: Claude Opus 5.5` trailer; reasoning levels were not recorded, so the level shown is the matrix level for the task type. The initial source upload (`f6d12d9`) and the workflow (`5c9651e`) were committed by the owner; the model that generated that code is not recorded.

#### P0 — Bootstrap and CI (2026-11-09)
- [x] Create the public repository and upload the source (`f6d12d9`) (not recorded)
- [x] Build workflow: unsigned `.ipa` job, optional TestFlight job, error summary, build-log artifact (`5c9651e`) (not recorded)
- [x] Restore the folder layout flattened by the web upload, restore `.gitignore`, drop the duplicate workflow; runs #1–#3 failed, branch run #4 and merge build #5 green — PR #1 (Opus 5.5 / high)

#### P1 — Room, Equipment, Object capture (2026-11-09)
- [x] Room scan with RoomPlan, USDZ/JSON export, `RoomReport` CSV and summary (`f6d12d9`) (not recorded)
- [x] Equipment scan: ARKit mesh, AR point-to-point measuring, OBJ/PLY/USDZ export (`f6d12d9`) (not recorded)
- [x] Object capture with on-device photogrammetry (`f6d12d9`) (not recorded)
- [x] Scan library, storage, formatting, 3D viewer with measuring, AR Quick Look (`f6d12d9`) (not recorded)
- [x] Object Capture state followed through `stateUpdates` (session is not `ObservableObject` in the iOS 26 SDK) — PR #1 (Opus 5.5 / high)

#### P2 — Line scan core (2026-11-09, PR #2, build #8)
- [x] AVFoundation LiDAR depth + synchronized video pipeline at 30 fps (Opus 5.5 / high)
- [x] Speed from image correlation, scaled by the tracked area's LiDAR distance; centred tracking (Opus 5.5 / high)
- [x] Recorder: `Video.mov`, `Depth.bin`, `Recording.json`, `Frames.csv`; depth kept if video fails (Opus 5.5 / high)
- [x] Playback with depth overlay, per-frame speed and speed timeline (Opus 5.5 / high)
- [x] Topographic map stitched by travel, variance statistics, profiles, CSV/PNG exports, map screen (Opus 5.5 / high)

#### P3 — Playback touch probe (2026-11-09, PR #3 build #10, PR #4 build #12)
- [x] Touch probe: current value, min/max with times, mean, std dev, trace — PR #3 (Opus 5.5 / high)
- [x] Sendable warning fix in probe sampling (`8563092`) — PR #3 (Opus 5.5 / high)
- [x] Whole picture selectable; readouts moved off the picture; fixed-height probe panel — PR #4 (Opus 5.5 / high)

#### P4 — Bubble level (2026-11-09, PR #5, build #14)
- [x] Gravity bubble level with Zero here / Reset, persisted zero (Opus 5.5 / high)
- [x] Surface tilt from a plane fit to the LiDAR depth (Opus 5.5 / high)
- [x] Tilt recorded per frame (`Recording.json`, `Frames.csv`) and shown in playback (Opus 5.5 / high)

#### P5 — Baseline calibration (2026-11-09, PR #6, build #17)
- [x] Baseline calibration: 90 frames, per-pixel trimmed mean of 60, 30 verify frames, plane fill (Opus 5.5 / high)
- [x] Height mode in live view, map, statistics, profiles, renderer and playback probe (Opus 5.5 / high)
- [x] Tilt-change and filter-mismatch warnings; baseline in `Documents/Calibration`, copied into recordings (Opus 5.5 / high)
- [x] Compile fix (optional binding in probe position text) after failed branch build #15 (Opus 5.5 / high)

#### P6 — Local speeds (2026-11-09, PR #7, build #19)
- [x] 6 × 4 zone block matching with backward matching for downstream zones, per-zone distance scaling (Opus 5.5 / high)
- [x] Recording screen: Fastest marker and speed at a tapped point (Opus 5.5 / high)
- [x] Playback: Fastest on screen and Speed here at the probe (Opus 5.5 / high)
- [x] `ZoneSpeeds.csv`, zone speeds in `Recording.json`, fastest zone in `Frames.csv` (Opus 5.5 / high)

#### P7 — Topographic replay (2026-11-09, PR #8, build #23)
- [x] `TopoGrid.bin` writer/reader; `TopoMapBuilder` writes it (Opus 5.5 / high)
- [x] Replay source: oldest → newest ordering, reveal positions, run-out, default target/tolerance (Opus 5.5 / high)
- [x] SceneKit strip scene: walls, tolerance planes, newest-line marker, axes, Map mode (Opus 5.5 / high)
- [x] Replay screen: transport, speed 0.1×–20×, along/across charts, colour bar, settings, Save image (Opus 5.5 / high)
- [x] Landscape unlock for the replay screen only (Opus 5.5 / high)
- [x] Auto-play on open, view defaults matched to the reference footage, file-list refresh (Opus 5.5 / high)

### P8 — Process alignment (in progress)

Branches: all fix branches (`test-infra`, `fix-line`, `fix-topo`, `fix-apps`, `cycle2-capture`, `cycle2-topo`, `cycle2-rest`, `cycle3-recovery`, `cycle3-apps`, `final-line`, `final-misc`, `rereview-fixes`, `rereview2-tests`) are merged into `process-alignment`. Cycles 1–3 converged on Critical/High/Medium. Re-reviews of the final review's fixes continue at Opus 5.5 / max until one yields no new findings; that review decides the merge into `main` (one PR). Record: [reviews/2026-11-10-M1.md](reviews/2026-11-10-M1.md).

Documentation and agent rules
- [x] P8.1 Requirements, design, technology recommendations and this plan in `docs/` (Opus 5.5 / max)
- [x] P8.2 `CLAUDE.md` at the repo root (Opus 5.5 / max)
- [x] P8.3 Correct the build guide for the discrepancies in [design §12](design.md#12-guide-vs-code-discrepancies) and for behaviour changed by the M1 fixes (Sonnet 5.5 / medium)
- [x] P8.4 README refresh: current modes incl. Line scan, pointer to the build guide and `docs/` (finding C-22) (Sonnet 5.5 / medium)

Unit tests and CI (branch `test-infra`, merged into `process-alignment`)
- [x] P8.5 Host-less XCTest target `PhoneLidarTests` compiling the pure-logic sources; first tests for formatting/CSV and `TopoGrid.bin` (Sonnet 5.5 / high)
- [x] P8.6 CI `unit-tests` job on the newest iOS Simulator, `pull_request` trigger, warning count in the build job, test job fails on warnings (finding C-11, C-21) (Sonnet 5.5 / high)
- [x] P8.7 Workflow and repo hardening: `permissions` block, secrets scoped to steps, pinned actions/tools, secret-file patterns in `.gitignore`, robust build-number step, `pipefail` in the summary step (findings C-9, C-10, C-19, C-20) (Sonnet 5.5 / high)
- [x] P8.8 Unit tests for `Depth.bin` round trip and truncation, `Baseline.build` on synthetic frames, `SpeedEstimator` on synthetically shifted images, `TopoMapBuilder` on a synthetic recording, `TopoReplaySource`/`TopoDisplayGrid`, `LineMath`, `ZoneGrid` (Sonnet 5.5 / high)

Milestone M1 reviews and fixes
- [x] P8.9 M1 review cycle 1: three fresh reviewers (line capture; topo/replay/playback; apps/storage/CI) — 3 Critical, 3 High, 20 Medium, 26 Low (Opus 5.5 / high)
- [x] P8.10 Record cycle 1 in `docs/reviews/2026-11-10-M1.md` (finding, severity, file:line, summary, branch, status) (Sonnet 5.5 / medium)
- [x] P8.11 Area A fixes, line capture A-1…A-12 (incl. Critical A-1 background/interruption, High A-2 write errors and folder deletion) — branch `fix-line` (Opus 5.5 / high)
- [x] P8.12 Area B fixes, topo/replay/playback B-1…B-18 — branch `fix-topo` (Opus 5.5 / high)
- [x] P8.13 Area C fixes, apps/storage C-1…C-8, C-12…C-18 (incl. Critical C-1 photo-library key, C-2 photo deletion; High C-3, C-4) — branch `fix-apps` (Sonnet 5.5 / high)
- [x] P8.14 Triage the additional findings reported during docs alignment (map cell rounding R-08, grid binning truncation, stale last speed after a direction change, CMMotionManager thread use, silent baseline-copy failure, Line-screen auto-lock, folder-name collisions) into cycle 2 (Opus 5.5 / high)
- [x] P8.15 M1 review cycles 2 and 3 on the changed code and its neighbours (Opus 5.5 / high)
- [x] P8.16 Update requirements traceability (statuses of FR-*-Not implemented items closed by the fixes), design (formats/algorithms changed by B-4, A-3, …), `README.md` and `CLAUDE.md` (Sonnet 5.5 / medium; redone after cycle 3 if its fixes change behaviour)
- [ ] P8.17 Final review of the whole codebase and docs (Opus 5.5 / max)
- [ ] P8.18 Merge order agreed by the orchestrator; every branch green (build + unit tests, 0 warnings) before merge (Sonnet 5.5 / medium)

Owner copy and revision log (orchestrator)
- [ ] P8.19 Sync a plain copy of `main` (no `.git`) to the owner's local folder (Haiku 5.5 / low)
- [ ] P8.20 Add the P8 entry (date, build number, commit, change, files) to `REVISIONS.md` in the owner's local folder (Sonnet 5.5 / medium)

### P9 — On-device validation (iPhone 17 Pro Max)

The owner runs each test on the device and shares the scan folders (or the listed files); an agent analyses them and records results in `docs/validation/<YYYY-MM-DD>-<test>.md` with the numbers, pass/fail and photos of the setup (no people, nothing confidential). Pass criteria marked *proposed* may be adjusted by the owner before the test; record the adjustment.

Common setup for line-scan tests: phone in the mount at about 1.0 m (record the measured lens-to-surface distance), portrait, USB-C power, angle readout within ±1°, bubble green, filtered depth, short shutter on with enough light, baseline calibrated on the empty surface right before the test, phone and mount untouched afterwards.

- [ ] **V1 Capture frame rate, data volume and endurance** — record 10 minutes of moving material on USB-C power. From `Recording.json`: frame intervals Δt = time[i+1] − time[i]; frame counts in `Recording.json`, `Frames.csv`, `ZoneSpeeds.csv` and `Depth.bin`; folder size per minute; note any "Hot" label. Pass: median Δt 33.3 ± 0.5 ms and ≥ 98 % of Δt < 50 ms (NFR-PERF-01); the recording completes and saves, no thermal shutdown (NFR-PERF-07); all frame counts equal (NFR-REL-01); report MB/min (NFR-STO-02). — owner runs; analysis (Sonnet 5.5 / high)
- [ ] **V2 Speed against a known conveyor speed** — run a conveyor at a constant speed known from an independent reference (VFD/drive feedback or encoder scaled to surface speed, or a tachometer wheel on the belt); textured material on the belt; record ≥ 60 s at each of two speeds; repeat 3 runs per speed. Mean of `speed_mm_s` in `Frames.csv` over the steady part (drop the first and last 2 s); tracked % (`speed_tracked` in `TopoStats.csv`). Pass: tracked ≥ 95 %; uncorrected error ≤ 2 % (*proposed*); with the scale factor from run 1 applied to runs 2–3, error ≤ ±0.3 % (NFR-ACC-02). — owner runs; analysis (Opus 5.5 / high)
- [ ] **V3 Travel against a measured length over a timed run** — mark two thin lines across a board a taped distance L apart (≥ 2.000 m, measured to ±1 mm); run the board under the phone at constant speed. In playback, place the probe at the picture centre and find the frames where each line crosses it (step frame by frame); compare the difference of `travel_mm` between those frames with L; also L / (t₂ − t₁) against the mean speed. Pass: uncorrected error ≤ 2 % (*proposed*); with the V2 scale factor, ≤ ±0.3 % (NFR-ACC-02); board length in the map within ±1 % after correction (NFR-ACC-06). — owner runs; analysis (Opus 5.5 / high)
- [ ] **V4 Height against gauge plates** — after baseline calibration, place flat plates of calliper-measured thickness (e.g. ≈ 5, 10, 25, 50 mm; each ≥ 100 × 100 mm because the real LiDAR spot spacing is ≈ 5 cm at 1 m, NFR-ACC-07) on the surface, record 20 s stationary, then 20 s moving if a conveyor is available. Read the probe mean at each plate centre (Current height and the min/max/mean statistics) and the mean of `TopoMap.csv` cells over the plate interior (≥ 30 mm from its edges). Pass: |measured − thickness| ≤ 2 mm per plate at ~1 m (NFR-ACC-01); probe statistics appear ≤ 2 s after lifting the finger (NFR-PERF-06). — owner runs; analysis (Opus 5.5 / high)
- [ ] **V5 Flat-surface σ after baseline** — calibrate on an empty flat surface; note `correctedStdDev` from `Baseline.json` and the live σ readout over 10 s; record 30 s of the empty surface (moving if possible). From `TopoStats.csv`: `height_mean`, `height_std_dev`, `height_p1`, `height_p99`. Pass (*proposed*, NFR-ACC-03): `correctedStdDev` ≤ 2.0 mm; `height_std_dev` ≤ 1.0 mm; absolute `height_mean` ≤ 1.0 mm. — owner runs; analysis (Opus 5.5 / high)
- [ ] **V6 Map coverage, completeness and build time** — record 60 s of material that fills the whole view at constant speed. Stopwatch from tapping Stop to the scan screen. From `TopoStats.csv`: `coverage`, `map_width`; from `AlongProfile.csv`: consecutive `along_mm` steps; from `TopoMap.csv`: count empty rows inside the material. Pass: coverage ≥ 80 % with the as-built definition (≥ 95 % once B-4 changes it to the observed extent) and no along-travel gaps (every step = `cell_size`) (NFR-ACC-06); no empty rows inside the material (R-08); across width of a board within ±1 % of its taped width (NFR-ACC-06); build time ≤ 10 s (NFR-PERF-03). — owner runs; analysis (Opus 5.5 / high)
- [ ] **V7 Replay timing against wall clock** — open the replay of the V6 recording; start an iOS screen recording; play from t = 0 at 1× for 60 s, then 15 s at 4× and 16×. From the screen recording compare the header time t at two points ≥ 30 s apart with the video's elapsed time; count visibly frozen frames of the strip. Pass: at 1× |Δt_replay / Δt_wall − 1| ≤ 1 % and at 4× the ratio is 4.00 ± 0.04 (NFR-PERF-05); no visible stutter at 1× and 16× (NFR-PERF-04). — owner runs; analysis (Sonnet 5.5 / high)
- [ ] **V8 Room dimensions against tape** — scan a rectangular room with clear walls; tape (or laser-measure) every wall length, the ceiling height and the floor length × width. Compare `RoomReport.csv` wall `width_m`, the maximum wall `height_m` and the summary floor area. Pass (*proposed*, NFR-ACC-04): each wall within ±2 % or ±5 cm (whichever is larger); height within ±3 cm; floor area within ±4 %. — owner runs; analysis (Sonnet 5.5 / high)
- [ ] **V9 Mesh point-to-point against tape** — on a machine or frame, choose five pairs of sharp features 0.3–3 m apart; tape each distance; measure each live with Set start/end point, then again in the 3D viewer on the saved mesh. Pass (*proposed*, NFR-ACC-05): every live and viewer measurement within ±1 cm or ±1 % (whichever is larger) of the tape value. — owner runs; analysis (Sonnet 5.5 / high)
- [ ] **V10 Zone speed uniformity** — from the V2 runs, the mean of each `ZoneSpeeds.csv` column over the steady part. Pass (*proposed*): every zone with ≥ 80 % readings within ±2 % of the main mean speed (FR-SPD-04); report zones that fail (edge zones point to lens distortion, R-01). — analysis only (Opus 5.5 / high)
- [ ] V11 Record the results, update NFR statuses in [requirements.md](requirements.md) §6 and the expected-performance section of the build guide (Sonnet 5.5 / medium)

### P10 — Backlog

Gaps between the requirements and the code that the M1 fixes do not cover, plus known limitations ([design §11](design.md#11-known-limitations-and-design-risks)).

- [ ] Speed/travel scale correction: per-mount factor entered from V2/V3, applied to speed and travel, stored as an optional field in `Recording.json` (FR-SPD-08, GC-10) (Opus 5.5 / high)
- [ ] Lens-distortion correction for speed scaling and map projection using `AVCameraCalibrationData.lensDistortionLookupTable` (R-01) (Opus 5.5 / high)
- [ ] Travel policy during lock loss: mark untracked spans in `Frames.csv`; evaluate interpolation (R-02). The reset of the last valid speed on direction change is done (P-3) (Opus 5.5 / high)
- [ ] Persist Line scan settings (raw depth, short shutter, direction) between visits (Sonnet 5.5 / high)
- [ ] Glove-friendly secondary controls (≥ 44 pt for Zero here, Reset, Recalibrate, Clear, ✕) (NFR-USE-02) (Sonnet 5.5 / high)
- [ ] Swift 6 language mode and strict concurrency: reduce the 8 `@unchecked Sendable` types, coalesce `LiveUpdate` delivery to the main actor (R-12, P-8). Single-queue `CMMotionManager` access is done (P-4) (Opus 5.5 / high)
- [ ] Profile per-frame processing on the device; move measured hot spots to Accelerate/vImage with regression tests on fixed inputs ([design §10.8](design.md#108-accelerate--vimage)) (Opus 5.5 / high)
- [ ] SceneKit → RealityKit migration design for the viewer and replay when the deployment target moves to iOS 18+ (R-11) (Opus 5.5 / max)
- [ ] Windows reader script for `Depth.bin`, `TopoGrid.bin` and `Recording.json` (Python, `lzfse`) to support P9 analysis (R-14) (Sonnet 5.5 / high)
- [ ] Storage use per scan and in total on the library screen; low-storage warning (R-15) (Sonnet 5.5 / high)
- [ ] Optionally save viewer measurements with the scan (FR-LIB-04 note) (Sonnet 5.5 / high)

#### Deferred review findings

All Low, from [reviews/2026-11-10-M1.md](reviews/2026-11-10-M1.md). Each needs no fix for correctness; the reason is why it waits.

- [ ] P-8 One main-actor task per frame, no coalescing: performance only, no observed problem; revisit after on-device profiling (P9) (Opus 5.5 / high)
- [ ] F-2 Playback decodes LZFSE and colours each frame on the main thread: performance only; needs on-device profiling first (Opus 5.5 / high)
- [ ] F-5 Capture session is configured on the main thread: one-off at screen open; moving it risks session-ordering regressions without device testing (Opus 5.5 / high)
- [ ] F-11 `store.save` then reload on main after Save image or a map build: infrequent, small folders (Sonnet 5.5 / high)
- [ ] B-13r Replay `SCNGeometry` is still rebuilt per change: performance only; part of the SceneKit → RealityKit/Metal backlog item (Opus 5.5 / high)
- [ ] Split `LineScanView.swift` (~1,070 lines) and `LinePlaybackView.swift` (~1,060 lines) below the ~800-line guideline; no behaviour change (Sonnet 5.5 / high)
- [ ] Move `ObjectPhotos.hasCompleteModel` and the Object resume decision into a Storage file so the test target can cover them (Sonnet 5.5 / high)
- [ ] Update every pinned action in `ios-build.yml` to a release on Node 24 (GitHub reports the Node 20 runtime as deprecated) (Sonnet 5.5 / medium)
- [ ] Check which unit-test class takes about 83 s on CI and whether it can be made faster (Sonnet 5.5 / medium)

## 7. Change log

Newest first. Build = run number of the `Build iOS app` workflow on `main` after the merge.

| Date | Build | PR / commit | Summary |
|---|---|---|---|
| 2026-11-10 | — | Process alignment (in progress, not merged) | On `process-alignment`: requirements, design and implementation plan, `CLAUDE.md`, README rewritten as the user guide; host-less `PhoneLidarTests` unit tests (392) and a `unit-tests` CI job on pull requests; CI hardening (read-only token, pinned actions and XcodeGen, hash-locked TestFlight tools, warnings as errors with a log gate, TestFlight after build and tests); M1 review cycles 1–3, the final review and its re-reviews: every finding fixed or deferred to P10 with a reason (totals in the review record): recordings stream to disk and survive interruptions, kills and low storage, with recovery from the library; map cell size, trimmed coverage/length/width, tolerant `scan.json`, Incomplete scans, Object photos kept and a finished model never rebuilt, speed/travel maths extracted and tested, held speed at Record limited to 2 s. Build number and merge commit are added at merge. |
| 2026-11-09 | #23 | PR #8 `topo-replay` (`1cf693e`; branch runs #20–#22) | Real-time topographic replay: scrolling 3D strip (newest line right, walls, tolerance planes, marker), Map view, along/across profiles, colour bar target ± 2 tolerances, transport and 0.1×–20× speed, gestures, settings, Save image; `TopoGrid.bin`; landscape on the replay screen only; auto-play; file-list refresh. Xcode 26.6, 0 warnings. |
| 2026-11-09 | #19 | PR #7 `local-speeds` (`ecba3d6`; branch run #18) | 6 × 4 zone speeds: Fastest marker and speed at a point while recording; Fastest on screen and Speed here in playback; `ZoneSpeeds.csv`, zone speeds in `Recording.json`, fastest zone in `Frames.csv`. Snapshot copied to the owner's folder. |
| 2026-11-09 | #17 | PR #6 `baseline-calibration` (`bbeaa30`; branch run #15 failed, #16 green) | Flat-surface baseline calibration and height mode across live view, map, statistics, profiles and probe; tilt/filter warnings; baseline stored and copied into recordings. |
| 2026-11-09 | #14 | PR #5 `bubble-level` (`073b0d7`; branch run #13) | Bubble level (gravity) with zero/reset, LiDAR surface tilt; tilt recorded per frame and shown in playback. |
| 2026-11-09 | #12 | PR #4 `probe-full-area` (`e1c41e5`; branch run #11) | Whole playback picture selectable for the probe; readouts moved off the picture. |
| 2026-11-09 | #10 | PR #3 `playback-probe` (`d8fad33`; branch run #9) | Touch probe with current, min/max (times), mean, std dev and trace; Sendable warning fix. |
| 2026-11-09 | #8 | PR #2 `line-scan` (`df83723`; branch runs #6, #7) | Line scan mode: LiDAR depth + video at 30 fps, speed from image correlation scaled by LiDAR distance, recording files, playback, topographic map with statistics and exports. |
| 2026-11-09 | #5 | PR #1 `fix-folder-layout` (`0687c62`; branch run #3 failed, #4 green) | Folder layout restored after the flattened web upload; Object Capture state via `stateUpdates`. First green build. |
| 2026-11-09 | #1, #2 failed | `f6d12d9`, `5c9651e` (no PR) | Initial upload (Room, Equipment, Object capture, viewer, library) and build workflow; builds failed because the upload flattened the folders. |
