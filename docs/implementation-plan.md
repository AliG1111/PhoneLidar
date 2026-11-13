# Phone LiDAR — Implementation plan

| | |
|---|---|
| Document | Process, model delegation, review protocol, phased checklists, change log |
| State | P11 remote link merged (PR #12, `cf7fbbc`, build #83; milestone M2, [reviews/2026-11-12-M2.md](reviews/2026-11-12-M2.md)). P12 flake topography (single-reading LiDAR map, laser line scan) and P13 side-wall calibration merged (PR #13, `df07d43`, build #85; milestone M3, [reviews/2026-11-12-M3.md](reviews/2026-11-12-M3.md)). Both review cycles ran until a review yielded no new findings. P14 automatic travel direction and free replay rotation merged (PR #15, `447f2a6`, build #91; review [reviews/2026-11-13-P14.md](reviews/2026-11-13-P14.md), no new findings at the end). P15 laser calibration watchdog merged (PR #17, `5449242`, build #96; review [reviews/2026-11-13-P15.md](reviews/2026-11-13-P15.md)). Next: P15.5 and P9 on-device validation (V1–V18). |
| Date | 2026-11-13 |
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
| P8 | Process alignment: docs, CLAUDE.md, unit tests in CI, milestone M1 reviews and fixes, final review | Done (PR #9, build #61) |
| P9 | On-device validation on the iPhone 17 Pro Max | Not started |
| P10 | Backlog | Open |
| P11 | Remote link: second phone controls a Line scan phone over direct phone-to-phone Wi-Fi (start/stop, status, auto-reconnect, copy scans for review) | Done (PR #12, build #83) |
| P12 | Flake topography: single-frame LiDAR map and laser line scan (milestone M3) | Done (PR #13, build #85) |
| P13 | Laser side-wall calibration and wall re-zero | Done (PR #13, build #85) |
| P14 | Automatic travel direction with manual override; unlimited rotation of the replay's 3D strip | Done (PR #15, build #91) |
| P15 | Laser calibration watchdog, Cancel/Close while calibrating, camera format restore after the LiDAR probe | Done (PR #17, build #96); on-device check open |

Build numbers are GitHub Actions run numbers of the `Build iOS app` workflow on `main` (artifact `PhoneLidar-unsigned-ipa-<n>`).

## 2. Model and reasoning matrix

| Task type | Model | Reasoning |
|---|---|---|
| Requirements, architecture, design, implementation planning, major design changes | Opus 5.5 | max |
| Milestone final review: whole codebase, tests and user guide, once at the end of a milestone | Opus 5.5 | max |
| Change review: the PR diff plus the code it calls or is called by (correctness, defects, security, performance, concurrency); also re-reviews of fixes | Opus 5.5 | high |
| Wording-only follow-ups after the milestone final review | Sonnet 5.5 | medium |
| Implementation in capture / signal-processing / concurrency / file-format code (`PhoneLidar/Line/*` pipeline, `SpeedEstimator`, `Baseline`, `TopoMapBuilder`, `TopoGridFile`, `TopoReplayData/Model`, `LineRecording`) and the remote link's networking, cryptography and transfer code (`PhoneLidar/Remote/*` except the views) | Opus 5.5 | high |
| Implementation of UI and routine features (SwiftUI views, settings, sharing, wiring, Room/Mesh/Object screens) | Sonnet 5.5 | high |
| Unit tests | Sonnet 5.5 | high |
| CI log triage and compile-error fixes | Sonnet 5.5 | medium |
| Docs upkeep (build guide, change log, checklists, CLAUDE.md, REVISIONS.md) | Sonnet 5.5 | medium |
| Bookkeeping check (review record, change log, checklist ticks, REVISIONS.md): consistency with git and CI | Orchestrator (no separate agent) | — |
| Mechanical work (renames, formatting, file inventory, searches, local-folder sync) | Haiku 5.5 | low |

- The agent that did a task self-reviews it at the same model and level before committing.
- Change reviews and the milestone final review are done by a fresh agent that did not write the code.
- Small edits the orchestrator can make in a few lines (bookkeeping, one-line doc fixes) are made directly; starting an agent costs more than the edit.
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

**Token budget** (owner's decision, 2026-11-11):
- **One session per task.** Start a fresh session for each P9/P10 item or feature, with `CLAUDE.md` and this plan as the starting context; do not continue a long multi-phase session.
- **At most two agents at a time**, so a run stays inside the 5-hour usage window. One agent does an area's fix and its tests together.
- **Read only what the task needs**: the diff, the files it touches and their direct callers; grep before opening a large file; read large files in parts.
- **CI**: dispatch once, then wait with a single `gh run watch <id> --exit-status` call instead of repeated polling; read only `--log-failed` on failure.
- **Bookkeeping in one place**: finding counts live only in the review record; the change log row is written once, at merge.
- **Local-folder sync**: the owner's computer downloads the `main` tarball from GitHub and copies it into the folder in one step (no file-by-file staging).

## 4. Self-review checklist

Run before every commit that completes a unit of work. Record anything deliberately left open in the PR body.

- [ ] **Correctness** — behaviour matches the requirement IDs and design sections; units (mm, mm/s, s, degrees; metres only in Room/Mesh/Object) and sign conventions ([design §6.1](design.md#61-coordinate-conventions)) are right; formulas checked by hand on one example.
- [ ] **Defects and edge cases** — empty or 1-frame recordings, missing/truncated/corrupt files, no texture lock, no baseline vs baseline, both travel directions, recordings from older builds (optional fields absent), division by zero, NaN/∞ (note: `JSONEncoder` throws on non-finite numbers), integer overflow (e.g. rows × columns), index bounds.
- [ ] **Concurrency** — each piece of state has one owner (main actor, `phonelidar.line.data`, `phonelidar.line.session`, detached task); nothing touches UI or `@Observable` state off the main actor; no blocking work on the main actor or in the display-link tick; tasks check cancellation after `await`; display links, observers and timers are torn down.
- [ ] **Memory and resources** — no unbounded growth during capture; per-frame allocations kept small; file handles closed; `CVPixelBuffer` locks balanced; large data processed off the main thread.
- [ ] **Data integrity** — atomic writes for metadata; captured data is never deleted on failure; on-disk formats stay backward compatible (new `Codable` fields optional; binary format changes bump the version and keep the old reader); frame counts stay in lock-step.
- [ ] **Error handling** — failures reach the user with a clear message; no `try?` on paths that write or read measurement data unless the fallback is documented.
- [ ] **Security and privacy** — no secrets, Apple IDs, keys, personal data, plant imagery or scan data committed; network code only in `Remote/` and only to the paired phone (authenticated, encrypted; names and sizes from the peer validated; frame limits); new permissions have purpose strings; workflow changes keep least privilege.
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

Cycle: review → triage → fix → CI green → re-review of the fixes and the code they touch → repeat **until a review yields no new findings** (owner's rule). "New" means any finding, of any severity, that is not already fixed or recorded in the P10 backlog with a reason. Critical/High/Medium are always fixed; a Low is fixed or, when the fix is risky or large, deferred to P10 with a reason, and the next review checks the fixes.

**Review scope** (owner's decision, 2026-11-11, to cut token use):
- The rule applies to **code, tests and the user guide (`README.md`)**. Review bookkeeping — the review record, change log, checklist ticks, `REVISIONS.md` — is written after the review it records and is checked by the orchestrator against git and CI; it is not sent for another review. Process docs (`CLAUDE.md`, this plan, requirements, design) are reviewed only when their content changes, not for bookkeeping edits.
- **Change review** (every PR that changes code or tests): one fresh Opus 5.5 / high reviewer reads the PR diff plus the code it calls or is called by, not the whole codebase. Re-reviews read only the fix diff.
- **Milestone final review**: one fresh Opus 5.5 / max review of the whole codebase, tests and user guide, once at the end of a milestone. Code findings are fixed and re-reviewed at Opus 5.5 / high on the fix diff; wording-only findings are fixed by Sonnet 5.5 / medium (or the orchestrator) without another review.
- Area-split reviews (several reviewers reading whole areas) are used only for a first review of a large new subsystem.
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

Branches: all fix branches (`test-infra`, `fix-line`, `fix-topo`, `fix-apps`, `cycle2-capture`, `cycle2-topo`, `cycle2-rest`, `cycle3-recovery`, `cycle3-apps`, `final-line`, `final-misc`, `rereview-fixes`, `rereview2-tests`) are merged into `process-alignment`. Cycles 1–3 converged on Critical/High/Medium. Re-reviews of the final review's fixes ran at Opus 5.5 / max until one yielded no new findings; the merge into `main` is one PR. Record: [reviews/2026-11-10-M1.md](reviews/2026-11-10-M1.md).

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
- [x] P8.17 Final review of the whole codebase and docs, re-reviewed until a review yielded no new findings (Opus 5.5 / max)
- [x] P8.18 Merge order agreed by the orchestrator; every branch green (build + unit tests, 0 warnings) before merge (Sonnet 5.5 / medium)

Owner copy and revision log (orchestrator)
- [x] P8.19 Sync a plain copy of `main` (no `.git`) to the owner's local folder (Haiku 5.5 / low)
- [x] P8.20 Add the P8 entry (date, build number, commit, change, files) to `REVISIONS.md` in the owner's local folder (Sonnet 5.5 / medium)

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
- [ ] **V12 Remote link range and throughput** — scanner mounted at its forming-line position, remote paired. Walk away from the mount in steps of 2 m (line of sight, then behind steel); at each step note the link state, the status age (readouts updating), Start → "Recording started" answer time, and the copy rate of a 60 s recording (MB/s on the Remote screen). Note where copies stall and where the link drops; walk back and time the automatic reconnect. Pass (*proposed*, NFR-PERF-08): status latency ≤ 1 s and copy ≥ 5 MB/s at 5 m line of sight; reconnect ≤ 15 s after returning into range (FR-RMT-06). — owner runs; analysis (Sonnet 5.5 / high)
- [ ] **V13 Remote control functional test** — with the remote connected: two recordings in a row started and stopped from the remote (FR-RMT-07, FR-RMT-09); during the second, walk out of range for 30 s and back (the recording continues and saves, FR-RMT-05); copy both scans, breaking the link once mid-copy (FR-RMT-11); open the map, replay and playback of a copy on the remote (FR-RMT-10); wrong pairing code ×5 shows a new code (FR-RMT-03). From the scanner's `Recording.json`: frame intervals as V1 with the remote connected (R-20). Compare file names and sizes of each copy with the scanner's folder. Pass: every step behaves as stated; V1 interval criteria still met. — owner runs; analysis (Sonnet 5.5 / high)
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
- [ ] Split `RemoteLink.swift` (~1,150 lines; scanner side, remote side, copy queue) below the ~800-line guideline: needs its private state opened to internal or a separate copy-queue type; no behaviour change, so it waits for the next change to the file (Opus 5.5 / high)
- [ ] Pairing without the offline code-recovery limit (R-19, NFR-SEC-06): a comparison step on both screens or a PAKE; needs an owner decision on the extra pairing step (Opus 5.5 / max)
- [ ] Move `ObjectPhotos.hasCompleteModel` and the Object resume decision into a Storage file so the test target can cover them (Sonnet 5.5 / high)
- [ ] Update every pinned action in `ios-build.yml` to a release on Node 24 (GitHub reports the Node 20 runtime as deprecated) (Sonnet 5.5 / medium)
- [ ] Check which unit-test class takes about 83 s on CI and whether it can be made faster (Sonnet 5.5 / medium)

### P11 — Remote link (owner's request, 2026-11-12)

Owner's decisions: direct phone-to-phone Wi-Fi; Line scan only; the scanning phone keeps running its scan when the link drops and reconnects by itself; the second phone starts and stops scans and copies the scan files to itself for review. Requirements FR-RMT-01…12, NFR-PERF-08, NFR-REL-07, NFR-SEC-06; design §3.9, §6.15, §7.20, §10.10. Branch `remote-link`, milestone **M2**, review record `docs/reviews/2026-11-12-M2.md`. Under the token budget this is one session: the orchestrator (Opus 5.5) writes the code; a task touching networking and UI takes the higher assignment.

- [x] P11.1 Requirements, design, plan for the remote link (Opus 5.5 / max)
- [x] P11.2 Pure logic: `RemoteProtocol`, `RemoteCrypto`, `RemoteTransfer` (Opus 5.5 / high)
- [x] P11.3 Unit tests for framing, records, handshake and channel, pairing window, listing, resume offsets, staging reconcile, progress, import record (Sonnet 5.5 / high; written with P11.2 by the orchestrator)
- [x] P11.4 Networking: `RemoteConnection` (handshake, channel, liveness, file sender/receiver), `RemoteListener`, `RemoteBrowser`, `ScannerSecrets`, `RemoteKeychain` (Opus 5.5 / high)
- [x] P11.5 `RemoteLink` service: roles, scanner side, remote side, reconnection, copy queue and import (Opus 5.5 / high)
- [x] P11.6 Line scan integration: `RemoteScannerTarget`, keep the screen open after a save, Remote button and chip (Opus 5.5 / high)
- [x] P11.7 Views: Remote screen, scanner sheet, Home section; `Info.plist` Local Network keys; `project.yml` test sources (Opus 5.5 / high)
- [x] P11.8 CI green (build + unit tests, 0 warnings) (Sonnet 5.5 / medium)
- [x] P11.9 Change review of the PR (area-split first review for a new subsystem: networking/crypto and integration/UI), fixes, re-reviews until no new findings (Opus 5.5 / high)
- [x] P11.10 Milestone M2 final review of the remote link and its integration (Opus 5.5 / max); code findings re-reviewed at Opus 5.5 / high
- [x] P11.11 README (user guide), requirements traceability, CLAUDE.md, change log; `REVISIONS.md` and the owner's local folder (Sonnet 5.5 / medium; orchestrator)

### P12 — Flake topography: single-frame LiDAR map and laser line scan (milestone M3)

Owner's request (2026-11-12): per-frame height of the passing strands instead of values averaged between frames, for line speeds of 100–1000 mm/s. Requirements FR-SFM-01…06, FR-LAS-01…10, NFR-PERF-09, NFR-ACC-08/09; design §13–§14. One branch `flake-topography`, one PR.

Review plan for M3 (token budget): P12 is a new subsystem, so its first review is the milestone final review: one fresh Opus 5.5 / max reviewer over the whole P12 diff and its callers (this counts as the PR's change review). Fixes are re-reviewed on the fix diff at Opus 5.5 / high until a review yields no new findings.

- [x] P12.1 Requirements, design §13–§14, this phase (Opus 5.5 / max)
- [x] P12.2 `MapCells` + `MapMethod`; split `TopoMapBuilder.build` into accumulation and a shared `finish`; single-reading LiDAR build (scan-line score), repeated-frame detection, `ScanLineProfiles.csv`, `TopoStats.mapMethod`/`sensor`, summary line (Opus 5.5 / high)
- [x] P12.3 `mapMethod` in `Recording.json`; Map setting on the Line scan screen (forces raw depth); map-screen method picker and rebuild via `MapRebuild` (capture + UI → Opus 5.5 / high)
- [x] P12.4 Laser pure logic: `LaserLineDetector`, `LaserGeometry` (calibration, formulas, baseline, shim, `LaserTravel`), `LaserRecording` (`Profiles.bin`, JSON, CSV), `LaserMapBuilder`, `TopoReplaySource.make(grid:direction:frames:)`, `SpeedEstimator` row crop (Opus 5.5 / high)
- [x] P12.5 `LaserCapturePipeline` and `LidarDistanceProbe` (Opus 5.5 / high)
- [x] P12.6 `LaserScanView`, `ScanKind.laser`, Home row, scan-detail section, laser branch of the map screen and replay (capture + UI → Opus 5.5 / high)
- [x] P12.7 Unit tests for P12.2 and P12.4; add the new pure-logic files to the test target (Sonnet 5.5 / high)
- [x] P12.8 CI green: app build and unit tests, 0 warnings (Sonnet 5.5 / medium for compile-error triage)
- [x] P12.9 M3 final review of the P12 diff (Opus 5.5 / max), fixes, re-reviews of the fix diffs until no new findings (Opus 5.5 / high); record in `docs/reviews/2026-11-12-M3.md`
- [x] P12.10 Build guide (`README.md`) sections for both modes, `CLAUDE.md` repo map, requirements statuses (Sonnet 5.5 / medium; written by the orchestrator, Opus 5.5, with the code to avoid a cold-start agent)
- [x] P12.11 PR into `main`; after merge: change-log row, project guide copy, owner's local folder and `REVISIONS.md` (orchestrator; local sync Haiku 5.5 / low)

P9 additions (owner runs on the device; analysis assignment in brackets):
- [ ] **V14 Laser height on shims** — camera at 0.5 m and 1.0 m; shim-calibrate with a 10 mm gauge; then gauges of 0.5, 1, 2, 5 mm (calliper-measured) on the belt, stationary 5 s and moving at 100 and 1000 mm/s. Pass (*proposed*, NFR-ACC-08): single readings within ±0.2 mm at 0.5 m and ±0.3 mm at 1 m (Opus 5.5 / high)
- [ ] **V15 Laser frame rate** — 60 s at 240 fps on moving material. From `LaserRecording.json` and `LaserFrames.csv`: active fps, dropped frames, frame intervals. Pass: dropped ≤ 2 % (NFR-PERF-09) (Sonnet 5.5 / high)
- [ ] **V16 Single-frame vs averaged LiDAR map** — one Line recording with Map = Single frame on a strand mat; rebuild as Averaged; compare `TopoStats` and profiles; report the repeated-frame share from the summary and `ScanLineProfiles.csv` (Opus 5.5 / high)

### P13 — Laser side-wall calibration and wall re-zero

Owner's request (2026-11-12): calibrate without clearing the belt, from the side walls (known wall-top height), 5 mm tolerance accepted. FR-LAS-11…15, design §14.9. Same branch and PR as P12; reviewed together with the M3 re-review fixes (one fresh Opus 5.5 / high change review of the diff since the previous review, repeated until no new findings).

- [x] P13.1 Requirements, design §14.9, error budget (Opus 5.5 / max)
- [x] P13.2 `LaserWalls` (laser term with tilt, detection, fit, re-zero shift, map crop), `LaserCalibration` fields, re-zero in `LaserMapBuilder` and the pipeline (Opus 5.5 / high)
- [x] P13.3 Laser screen: method picker, wall inputs, level readout and zero, wall overlay, re-zero switch (capture + UI → Opus 5.5 / high)
- [x] P13.4 Unit tests `LaserWallsTests` incl. the 5 mm budget (orchestrator, Opus 5.5, written with the code)
- [x] P13.5 Change review until no new findings; guide; PR with P12

P9 addition:
- [ ] **V17 Side-wall calibration on the line** — measure h_w (±1 mm), H (tape, ±5 mm), the laser angle (digital gauge, ±0.1°), zero the level; calibrate on the walls with flakes on the belt; compare mat heights with an empty-belt shim calibration made at a shutdown, and with a known board on the belt. Pass: within ±5 mm (FR-LAS-15) (Opus 5.5 / high)

### P14 — Automatic travel direction and free replay rotation (owner's request, 2026-11-13)

Owner's request: rotate the topographic map in all orientations without limits; detect the direction of the scanned material automatically, with a manual override for when the detection has trouble. Requirements FR-DIR-01…06, FR-RPL-05/06/08, FR-LINE-04, FR-SPD-06, FR-LAS-06; design §6.2, §6.11, §6.16, §7.18. Branch `auto-direction-free-rotation`, one PR. One session (token budget): the orchestrator (Opus 5.5) writes code, tests and docs (a task touching capture and UI takes the higher assignment); one fresh change reviewer.

- [x] P14.1 Requirements FR-DIR-01…06 and replay gesture changes, design §6.16 and §6.11, this phase (Opus 5.5 / max)
- [x] P14.2 `TravelDirectionDetector` + `DirectionSetting`; `SpeedEstimator.searchesBothWays` (Opus 5.5 / high)
- [x] P14.3 Line and laser pipelines: detection while not recording, direction fixed per recording, generation echo; screens: picker, readout, Record refusal, summary line (capture + UI → Opus 5.5 / high)
- [x] P14.4 `ReplayOrientation` (quaternion trackball, twist, angles); scene camera with fixed scale, pivot at the window centre, light on the camera; gestures and settings sliders (Opus 5.5 / high)
- [x] P14.5 Unit tests: detector, two-way search, orientation (Sonnet 5.5 / high; written with the code by the orchestrator)
- [x] P14.6 CI green: app build and unit tests, 0 warnings (Sonnet 5.5 / medium for compile-error triage) — branch run 43441265753, PR run 43443688002
- [x] P14.7 Change review of the PR diff and its callers (fresh Opus 5.5 / high), fixes, re-reviews until no new findings; record in [reviews/2026-11-13-P14.md](reviews/2026-11-13-P14.md)
- [x] P14.8 Build guide (`README.md`), `CLAUDE.md` repo map (Sonnet 5.5 / medium; written by the orchestrator with the code)
- [x] P14.9 PR into `main`; after merge: change-log row, project guide copy, owner's local folder and `REVISIONS.md` (orchestrator)

P9 addition:
- [ ] **V18 Direction detection and free rotation** — Line scan and Laser line scan with Direction Auto: open the screen with the line stopped (readout "Detecting…", Record refused), start the line (time to "detected"), run both directions if the conveyor can reverse, and a blank surface (stays undetected; manual override records). Replay: turn the strip through full turns in every direction, view from below, twist, double-tap reset. Pass: detection ≤ 1 s after textured material moves; never the wrong direction over 10 starts per direction; rotation never stops at a limit (Sonnet 5.5 / high)

### P15 — Laser calibration watchdog (first on-device test, 2026-11-13)

The owner's first Laser line scan test stayed on "Calibrating baseline (keep the belt empty)…" with every control and Close disabled. With frames arriving the capture always ends in ≈ 1 s, so the camera had stopped delivering frames and nothing ended the capture.

- [x] P15.1 `LaserCaptureWatch` (pure: 2 s frame gap, max(5 s, 4 × expected) limit, reasons with frame counts, fps, size, drops); `collectRows` returns `LaserRowCapture`, interruptions and errors pass their text; `restoreFormat()` in `start()` (Opus 5.5 / high)
- [x] P15.2 Screen: calibration token, **Cancel calibration**, Close available while calibrating, progress % in the status, stop-reason notices, lens restored after the LiDAR probe (Opus 5.5 / high)
- [x] P15.3 Unit tests `LaserCaptureWatchTests` (written with the code)
- [x] P15.4 CI green, 0 warnings (branch runs 43487895634, 43489100049; PR run 43490810844); change review W1 (Medium), W2, W3 (Low) fixed; re-review R1, R2 (Low, wording) fixed; PR #17 merged (`5449242`, build #96)
- [ ] P15.5 On device: repeat the baseline calibration; if it stops, the message names the cause (no frames / slow camera / interruption)

## 7. Change log

Newest first. Build = run number of the `Build iOS app` workflow on `main` after the merge.

| Date | Build | PR / commit | Summary |
|---|---|---|---|
| 2026-11-13 | #96 | PR #17 `laser-calibration-watchdog` (`5449242`; PR run 43490810844, branch runs 43487895634, 43489100049) | P15: first on-device laser test stuck on "Calibrating baseline…" with Close disabled. Calibration captures now stop with a reason after a 2 s frame gap (camera restarted) or past max(5 s, 4 × expected); interruptions pass their text; progress % in the status; Cancel calibration; Close available while calibrating; camera format, frame rate and focus restored after the LiDAR height probe; Close cancels the probe. Change review W1 (Medium), W2, W3 (Low) and re-review R1, R2 (Low) fixed. FR-LAS-16. |
| 2026-11-13 | #91 | PR #15 `auto-direction-free-rotation` (`447f2a6`; PR runs 43443688002, 43445162943, branch run 43441265753) | P14: Direction Auto (default) / Right → Left / Left → Right on Line scan and Laser line scan — two-way main search while not recording, detection from 12 of the last 15 confident shifts, no speed until detected, Record refused until detected or when the detection just changed, direction fixed per recording, summary note; replay 3D strip rotates without limits (quaternion trackball, two-finger roll, tilt/turn/roll sliders, fixed scale, pivot at the window centre, light on the camera). Change review R1 (Medium) and R2 (Low) fixed; re-review: no new findings. 698 unit tests. |
| 2026-11-13 | #85 | PR #13 `flake-topography` (`df07d43`; PR run 43433878330 on the merge of `main`) | P12/P13 (milestone M3): single-reading LiDAR map (one reading per cell, repeated frames skipped, `ScanLineProfiles.csv`, map-method picker and rebuild); new scan mode Laser line scan (camera sheet-of-light triangulation, `Profiles.bin`, `LaserRecording.json`, `LaserFrames.csv`, `LaserCalibration.json`, shim or angle scale, LiDAR camera height, ≈ 60 Hz speed tracking, map and replay); side-wall calibration with laser angle and camera tilt, per-frame wall re-zero, map cropped inside the walls, 5 mm error budget. Final review and 6 re-reviews until no new findings (M2-…–M2V- IDs). Numbered P12/P13/M3 after the remote link kept P11/M2; merged after #12 (owner's decision). |
| 2026-11-13 | #83 | PR #12 `remote-link` (`cf7fbbc`; PR run 43268590932) | P11 (milestone M2): remote link — a second iPhone pairs with a Line scan phone over peer-to-peer Wi-Fi, starts/stops recordings, shows status and copies scans; encrypted, authenticated link, reconnection, resumable copy. Review cycles until no new findings. Merged by the P12/P13 orchestrator at the owner's request. |
| 2026-11-12 | — (docs only, no build) | PR #11 `token-efficiency` | Review scope and token budget (owner's decision): the "until no new findings" rule covers code, tests and the user guide; bookkeeping is checked by the orchestrator, not re-reviewed; one Opus 5.5 / high change review per PR on the diff and its callers; one Opus 5.5 / max final review per milestone; one session per task, at most two agents at a time, single CI watch, one-step local sync. Updated §2, §3, §5 and `CLAUDE.md`. |
| 2026-11-11 | #61 | PR #9 `process-alignment` (`4fa93c7`; PR run #60, branch run #59) | Process alignment (P8): requirements, design and implementation plan, `CLAUDE.md`, README rewritten as the user guide; host-less `PhoneLidarTests` unit tests (392) and a `unit-tests` CI job on pull requests; CI hardening (read-only token, pinned actions and XcodeGen, hash-locked TestFlight tools, warnings as errors with a log gate, TestFlight after build and tests); M1 review cycles 1–3, the final review and its re-reviews: every finding fixed or deferred to P10 with a reason (totals in the review record): recordings stream to disk and survive interruptions, kills and low storage, with recovery from the library; map cell size, trimmed coverage/length/width, tolerant `scan.json`, Incomplete scans, Object photos kept and a finished model never rebuilt, speed/travel maths extracted and tested, held speed at Record limited to 2 s. Not yet verified on a device (P9). |
| 2026-11-09 | #23 | PR #8 `topo-replay` (`1cf693e`; branch runs #20–#22) | Real-time topographic replay: scrolling 3D strip (newest line right, walls, tolerance planes, marker), Map view, along/across profiles, colour bar target ± 2 tolerances, transport and 0.1×–20× speed, gestures, settings, Save image; `TopoGrid.bin`; landscape on the replay screen only; auto-play; file-list refresh. Xcode 26.6, 0 warnings. |
| 2026-11-09 | #19 | PR #7 `local-speeds` (`ecba3d6`; branch run #18) | 6 × 4 zone speeds: Fastest marker and speed at a point while recording; Fastest on screen and Speed here in playback; `ZoneSpeeds.csv`, zone speeds in `Recording.json`, fastest zone in `Frames.csv`. Snapshot copied to the owner's folder. |
| 2026-11-09 | #17 | PR #6 `baseline-calibration` (`bbeaa30`; branch run #15 failed, #16 green) | Flat-surface baseline calibration and height mode across live view, map, statistics, profiles and probe; tilt/filter warnings; baseline stored and copied into recordings. |
| 2026-11-09 | #14 | PR #5 `bubble-level` (`073b0d7`; branch run #13) | Bubble level (gravity) with zero/reset, LiDAR surface tilt; tilt recorded per frame and shown in playback. |
| 2026-11-09 | #12 | PR #4 `probe-full-area` (`e1c41e5`; branch run #11) | Whole playback picture selectable for the probe; readouts moved off the picture. |
| 2026-11-09 | #10 | PR #3 `playback-probe` (`d8fad33`; branch run #9) | Touch probe with current, min/max (times), mean, std dev and trace; Sendable warning fix. |
| 2026-11-09 | #8 | PR #2 `line-scan` (`df83723`; branch runs #6, #7) | Line scan mode: LiDAR depth + video at 30 fps, speed from image correlation scaled by LiDAR distance, recording files, playback, topographic map with statistics and exports. |
| 2026-11-09 | #5 | PR #1 `fix-folder-layout` (`0687c62`; branch run #3 failed, #4 green) | Folder layout restored after the flattened web upload; Object Capture state via `stateUpdates`. First green build. |
| 2026-11-09 | #1, #2 failed | `f6d12d9`, `5c9651e` (no PR) | Initial upload (Room, Equipment, Object capture, viewer, library) and build workflow; builds failed because the upload flattened the folders. |
