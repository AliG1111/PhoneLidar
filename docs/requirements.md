# Phone LiDAR — Requirements

| | |
|---|---|
| Document | Functional and non-functional requirements, constraints, acceptance criteria, traceability |
| Describes | `main` at `4fa93c7` (PR #9, build #61): build #23 plus the P8 docs, unit tests, CI hardening and the M1 review fixes (cycles 1–3, the final review and the re-reviews), verified against the source code |
| Date | 2026-11-10 |
| Companion documents | [design.md](design.md) (architecture, algorithms, file formats), [implementation-plan.md](implementation-plan.md) (phases, change log), [../CLAUDE.md](../CLAUDE.md) (agent rules), the user guide [`../README.md`](../README.md) |

Requirements describe the system as built. Where the user guide (`README.md`) and the code disagree, the code is described here and the difference is listed in [design.md §12](design.md#12-guide-vs-code-discrepancies). Requirements that the code does not meet are kept with status **Not implemented** so they trace to the backlog and the review findings. Review IDs (`A-2`, `B-4`, `C-1`, `P-1`, `F-6`, …) refer to the M1 review ([reviews/2026-11-10-M1.md](reviews/2026-11-10-M1.md)); every requirement that cycle 1 and 2 found missing is now implemented and listed as *Implemented – not verified on device*. The user guide is `README.md`; the owner's local copy and the claude.ai project copy are synced by the orchestrator.

---

## 1. Purpose and scope

Phone LiDAR is an iPhone app that uses the LiDAR scanner and cameras to measure rooms, equipment, objects and moving material. It is built, signed and distributed without a Mac (GitHub Actions builds an `.ipa`; the owner installs it from Windows).

In scope (v1, implemented):

| Mode | Purpose | Apple frameworks |
|---|---|---|
| Room scan | Dimensioned room model and CSV report | RoomPlan |
| Equipment scan | Raw LiDAR mesh of machinery or a work area with live point-to-point measuring | ARKit scene reconstruction, RealityKit `ARView` |
| Object capture | Photo-textured, real-scale model of a part | RealityKit Object Capture, `PhotogrammetrySession` |
| Line scan | Fixed phone above moving material: synchronized LiDAR depth + video recording, surface speed (overall and 24 zones), baseline (flat-surface) calibration, bubble level, playback with a touch probe, topographic map with variance statistics, real-time topographic replay | AVFoundation (`builtInLiDARDepthCamera`), CoreMotion, SceneKit, Swift Charts |

Common functions: scan library, 3D viewer with measuring, AR Quick Look, sharing, Files-app access.

Out of scope: cloud storage or any network service, multi-device capture, user accounts, App Store distribution, Android, iPad layouts, real-time control outputs to plant systems (PLC, historian).

## 2. Users and operating context

| Item | Description |
|---|---|
| Primary user | The owner: a controls and automation engineer in OSB (oriented strand board) manufacturing. Technical, comfortable with CSV/Excel and engineering units; not an iOS developer; works from a Windows PC. |
| Device | iPhone 17 Pro Max (iOS 26). The app supports any LiDAR iPhone on iOS 17+. |
| Line scan context | Plant floor above a forming line (loose strand mat) or a finished-board conveyor. Phone in portrait, camera pointing straight down, rigid vibration-isolated mount, USB-C power, about 1–1.5 m above the surface (up to ≈ 2.9 m to see a 12 ft / 3.66 m width). Material moves right → left on the screen by default. Conditions: dust, vibration, heat, variable lighting (short shutter needs light), noise, gloves, limited time at the mount. |
| Room context | Plant rooms, offices, control rooms; walked by hand. |
| Equipment context | Machinery, piping, conveyors; hand-held at 0.5–3 m. |
| Object context | Parts and assemblies from about 10 cm to a few metres, walked around in three loops. |
| Data consumers | The owner on Windows: Excel (CSV), Blender / MeshLab / CloudCompare (OBJ, PLY, USDZ), video players (HEVC), custom scripts (Depth.bin, TopoGrid.bin). |

## 3. Use cases

| ID | Use case | Main flow | Requirements |
|---|---|---|---|
| UC-01 | Measure a room | Home › Room scan › walk the room › Done scanning › Save scan › review summary › share RoomReport.csv / Room.usdz | FR-ROOM-*, FR-LIB-* |
| UC-02 | Scan and measure equipment | Home › Equipment scan › sweep until covered › Set start/end point › Save › open in viewer or AR Quick Look | FR-MESH-*, FR-LIB-04 |
| UC-03 | Capture a part | Home › Object capture › Detect object › Start capture › three loops › Finish › wait for reconstruction › open model | FR-OBJ-* |
| UC-04 | Set up a line-scan mount | Mount phone › align (angle ≈ 0°) › level (bubble green) › Calibrate baseline on the empty surface | FR-CAL-*, FR-LINE-01…04 |
| UC-05 | Record moving material | Record › material passes › Stop › map builds › scan opens | FR-LINE-05…09, FR-SPD-*, FR-TOPO-* |
| UC-06 | Inspect a recording | Play back with the depth overlay; touch probe for height/distance and speed at a point; min/max over the recording | FR-PLAY-* |
| UC-07 | Analyse thickness / flatness | Topographic map and statistics; export TopoMap.csv, TopoStats.csv, profiles | FR-TOPO-*, FR-EXP-* |
| UC-08 | Review like the X-ray mat-density replay | Topographic replay at 0.1×–20× with target ± tolerance colouring; save an image | FR-RPL-* |
| UC-09 | Move data to Windows | Share files (AirDrop, Mail, OneDrive) or copy from Files › On My iPhone › Phone LiDAR | FR-LIB-01, FR-LIB-03 |

## 4. Conventions

- IDs are stable. New requirements get the next free number in their group; retired requirements keep their ID with status *Retired*.
- Units: line-scan values are millimetres, mm/s, seconds and degrees internally and in files; Room/Mesh/Object geometry is metres (Apple frameworks). User-facing lengths add feet-inches, speeds add m/min and ft/min.
- "Portrait picture" = the camera image as shown on the portrait recording screen. "Across" = top → bottom of the portrait picture; "along" = the travel direction (right → left by default). Full conventions: [design.md §6.1](design.md#61-coordinate-conventions).
- Status values (traceability table, §8):
  - **Implemented** — code is on `main`, builds in CI, and its behaviour can be confirmed without the device (file formats, stitching and statistics maths, storage), by code inspection and simulator unit tests (the `PhoneLidarTests` bundle).
  - **Implemented – not verified on device** — needs the iPhone, its camera/LiDAR, or data recorded on it to confirm. No on-device verification is recorded in the repo, the user guide or the revision log; phase P9 of the plan covers it. Requirements closed by the M1 fixes are listed here until P9 or a CI run on the merged code supports a stronger status.
  - **Not implemented** — required but not in the code; tracked in the plan (P8 fixes or P10 backlog).

## 5. Functional requirements

Source paths in this section are relative to `PhoneLidar/`.

### 5.1 App shell (FR-APP)

| ID | Requirement | Acceptance criteria |
|---|---|---|
| FR-APP-01 | The home screen offers four new-scan modes (Room scan, Equipment scan (LiDAR mesh), Object capture, Line scan (moving material)), each with a one-line description. A mode whose capability check fails is disabled and reads "Not supported on this device." Checks: `RoomCaptureSession.isSupported`, `ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)`, `ObjectCaptureSession.isSupported`, `LineCapturePipeline.isSupported` (a back `builtInLiDARDepthCamera` exists). | On the iPhone 17 Pro Max all four rows are enabled. On a device or simulator without the capability the row is disabled with the "Not supported" text. |
| FR-APP-02 | A mode opens as a full-screen cover. When it finishes with a saved scan, the cover closes and the scan's detail screen is pushed 0.45 s later; Cancel/Close returns to Home. | Saving any scan type ends on its detail screen; cancelling ends on Home with no new scan. |
| FR-APP-03 | Home lists saved scans newest first (kind icon, name, capture date and time). Swipe-to-delete (no full-swipe) asks "Delete this scan and all of its files?" and removes the scan folder only after confirmation. The same confirmation guards the scan screen's Delete and the delete of incomplete scans. Delete is not offered for an interrupted recording while a recovery is running (G-4). | Order follows `created`, descending. Deleting removes `Documents/Scans/<folder>/`; a full swipe does not delete. |
| FR-APP-04 | The UI is portrait-only except the Topographic replay, which allows every orientation except upside-down, rotates to landscape on entry and back to portrait on exit. | Outside the replay the UI does not rotate. Entering the replay rotates to landscape; leaving restores portrait. |
| FR-APP-05 | Camera access uses the system permission prompt with the `NSCameraUsageDescription` purpose string. | The first capture shows the iOS prompt with the app's text. |
| FR-APP-06 | Before a capture mode starts, check camera authorization; when access is denied, explain and offer a Settings link. Room, Equipment and Object capture show "Camera is off" with **Open Settings** and **Close**; Line scan shows "Camera access is off for Phone LiDAR. Turn it on in Settings › Privacy & Security › Camera, then reopen Line scan." with **Open Settings**. | With camera access denied, each capture screen shows an explanation and a Settings button instead of a black view or a raw error. |
| FR-APP-07 | Sharing to "Save Image" / "Save Video" from any share sheet works without crashing (photo-library add permission declared). | Saving a PNG or the video to Photos from the share sheet succeeds or shows the iOS prompt; the app does not terminate. |

### 5.2 Room scan (FR-ROOM)

| ID | Requirement | Acceptance criteria |
|---|---|---|
| FR-ROOM-01 | Guided capture in Apple's `RoomCaptureView` (one view and session per screen). Cancel stops scanning; Done scanning stops the session and shows a spinner until RoomPlan presents the processed room; then Save scan. | Save scan is enabled only after the processed room arrives. |
| FR-ROOM-02 | Save writes `Room.usdz` (parametric export; a failure aborts the save and shows the error) and `RoomMesh.usdz` (mesh export; skipped silently on failure). | Both files exist after a normal save; the scan's primary model is `Room.usdz`. |
| FR-ROOM-03 | Save writes `CapturedRoom.json` (the `CapturedRoom` value encoded with `JSONEncoder`, pretty-printed, sorted keys, ISO 8601 dates). | The file decodes as `CapturedRoom`. |
| FR-ROOM-04 | Save writes `RoomReport.csv`: one row per wall, door, window, opening, floor and object with type, category, number, width/height/depth in m (4 decimals) and feet-inches, centre x/y/z in m (4 decimals), confidence. | Row count of the element table = walls + doors + windows + openings + floors + objects, plus the header; the totals block of FR-ROOM-07 follows it. Format: [design §7.4](design.md#74-room-scan). |
| FR-ROOM-05 | Summary lines (saved in `scan.json`, shown on the scan screen): wall count and total wall length, maximum wall height, floor area (sum of floor polygon areas; fallback width × height per floor), counts of doors, windows, openings and objects, each wall/door/window W × H and each object W × H × D (m). Lengths also in ft-in, area also in ft². | Summary matches the CSV values for the same scan. |
| FR-ROOM-06 | A RoomPlan processing error is shown in a red banner while the result can still be saved; a save error is shown and Save is re-enabled. A RoomPlan session failure ends the scan with a message. Saving runs off the main thread while the button reads "Saving…". | Forced export failure shows the message and allows a retry. |
| FR-ROOM-07 | `RoomReport.csv` also carries the totals (wall count, total wall length, maximum wall height, floor area) in a separate block after an empty line, with its own header `summary_item,value,unit`, in m / ft_in and m2 / ft2, so no total sits in an element column such as `width_m`. | The CSV ends with the totals block; the values match the scan summary. |

### 5.3 Equipment scan (FR-MESH)

| ID | Requirement | Acceptance criteria |
|---|---|---|
| FR-MESH-01 | ARKit world tracking with scene reconstruction `.meshWithClassification` when supported (else `.mesh`), `.sceneDepth` when supported, horizontal and vertical plane detection, scene-understanding collision and occlusion. The reconstructed mesh is drawn as an overlay that the eye button hides and shows. | Mesh overlay grows while sweeping; the eye button toggles it. |
| FR-MESH-02 | Point-to-point measuring at the centre crosshair (drawn inside the ARView, so it marks exactly the sampled point) ("Set start point" / "Set end point") or at a tapped point. The 3D point comes from a hit test against the reconstructed mesh, falling back to a raycast onto an estimated plane; when neither hits, "No surface found there…" is shown. Completed measurements are labelled M1, M2, …, drawn with yellow markers and a bar, and the last four are listed in m (3 decimals) and ft-in. | A measurement between two features appears in the list and in the 3D view. |
| FR-MESH-03 | Undo removes a pending start point; otherwise the last measurement and its markers. | After Undo the list and markers match the remaining measurements. |
| FR-MESH-04 | Save copies the mesh out of ARKit, then merges every `ARMeshAnchor` of the current frame into one world-space mesh (metres, Y up, per-vertex normals) and writes `Mesh.obj` (streamed in chunks), `Mesh.ply` and `Mesh.usdz` in the background with a stage label and progress bar. The AR session keeps running until the save has succeeded (a failed save leaves no partial folder and can be retried). The primary model is `Mesh.usdz`, or `Mesh.obj` when the USDZ write fails. Without mesh anchors the save fails with "No LiDAR mesh yet…". | Files open in Blender/MeshLab at real scale. |
| FR-MESH-05 | `Measurements.csv` is written when at least one measurement exists, and measurements are stored in `scan.json`. Summary: overall extents (W × H × D), vertex and triangle counts, "Units: metres, Y axis up", one line per measurement. | CSV rows equal the measurement count; values match the on-screen list. |

### 5.4 Object capture (FR-OBJ)

| ID | Requirement | Acceptance criteria |
|---|---|---|
| FR-OBJ-01 | Guided Object Capture (`ObjectCaptureView` plus overlay): Detect object (ready) → Start capture (detecting) → "Photos: n / max" and Finish (capturing); a hint per state; Cancel. | Each state shows its button and hint. |
| FR-OBJ-02 | On iOS 18 or later the ready state also offers Area mode (capture without a bounding box). | Button visible on iOS 18+, absent on iOS 17. |
| FR-OBJ-03 | When capture completes, the capture session is released and on-device photogrammetry (`PhotogrammetrySession`, detail `.reduced`, checkpoint folder) writes `Model.usdz` with a progress bar and percentage. The checkpoint folder is deleted after success; photos stay in `Images/`. | `Model.usdz` opens in the viewer and in AR Quick Look at real scale. |
| FR-OBJ-04 | Cancel during capture stops the session and deletes the incomplete scan folder (after "Discard this capture?" once photos exist). A capture-session failure or reconstruction error shows a message. The photos are never deleted once the capture has finished (FR-OBJ-05); only a capture with no photos at all is removed. | No folder remains after Cancel during capture; Close after a failed reconstruction keeps the photos. |
| FR-OBJ-05 | After a reconstruction failure or **Stop**, keep the photos as a scan (no model, summary "Reconstruction failed: …") and offer **Retry reconstruction** (on the failure screen and on the scan screen). If the model was built but `scan.json` could not be written, "3D model built, but not saved to the library" offers **Try saving again**, which rewrites only the record and never deletes `Model.usdz`. The scan record is also written before the long reconstruction starts. Close on that screen tries the save once more; afterwards the scan screen offers **Add the finished model** instead of **Retry reconstruction**, and a complete `Model.usdz` is never rebuilt or deleted (G-3). If no scan record could be written at all, the failure screen says the photos are kept in the scan folder and gives the Files-app path (G-7). | A failed reconstruction leaves a scan with shareable photos and a Retry action. |
| FR-OBJ-06 | Summary: photo count and a note that `Model.usdz` is textured and at real-world scale. | Shown on the scan screen. |
| FR-OBJ-07 | Keep the screen awake during capture and reconstruction (also in Room and Equipment capture) and restore auto-lock when the screen goes away. | A multi-minute reconstruction completes with auto-lock set to 30 s. |

### 5.5 Line scan capture (FR-LINE)

| ID | Requirement | Acceptance criteria |
|---|---|---|
| FR-LINE-01 | Open the back LiDAR depth camera with synchronized video and depth (`AVCaptureDataOutputSynchronizer`). Format: among unbinned formats with depth support, the best score of 4:3 aspect (+1000), width 1920 (+500) or 1280–2016 (+200), 8-bit 4:2:0 (+100), 30 fps capable (+50); depth = widest `DepthFloat32` format (else widest). Frame rate fixed at 30 fps when supported; continuous autofocus; late video and depth frames discarded; video kept in sensor-native orientation. | `Recording.json` shows a 4:3 video size; median frame interval ≈ 33.3 ms (P9 test V1). |
| FR-LINE-02 | Live portrait preview with a depth overlay updated every second frame: distance mode uses the frame's P2–P98 range (dark blue = farthest, dark red = closest); height mode per FR-CAL-06. Overlay strength slider (default 0.55); legend with end values and span. | Overlay aligns with the picture; the legend tracks the scene. |
| FR-LINE-03 | Live readouts: speed (FR-SPD-02); median distance of the central half of the depth map (mm); texture lock % (match quality × 100); travel angle (when the along shift exceeds 2 px); flatness σ over the central 80 % (mm); centre height (height mode); status (Starting…, Ready, "● REC m:ss · N frames", Saving…, Building map…, Error); "Hot" label at serious or critical thermal state. | Values update while the camera runs; status follows the phase. |
| FR-LINE-04 | Settings before recording: Raw LiDAR depth (default off = filtered), Short shutter 1/1000 s (default on; continuous auto exposure with the maximum exposure duration limited to 1/1000 s, clamped to the format, so ISO rises instead and exposure keeps following the light; off = the format's default limit), Direction (default right → left). The three controls are locked while a baseline is calibrated (FR-CAL-09). Settings are not persisted between visits. | Toggles change the live behaviour; reopening the screen restores the defaults. |
| FR-LINE-05 | Record creates `Documents/Scans/line_<yyyy-MM-dd_HHmmss>/`. From the next frame it writes `Video.mov` (HEVC, 16 Mbit/s average, portrait rotation metadata, 5 s movie fragments) and, frame by frame as the recording runs, one `Depth.bin` record, one `Recording.json` frame line (compact JSON, header first), and one row each in `Frames.csv` and `ZoneSpeeds.csv`; it copies the active baseline (`Baseline.bin`, `Baseline.json`) into the folder (a failed copy is reported in the scan summary) and keeps a hidden `.recording-in-progress` marker until the saved recording reads back. Stop finishes the video first, then closes the data files. The screen is kept awake for the whole time the Line scan screen is open. Memory use does not grow with the recording length. | After Stop the folder holds all listed files; frame counts in `Recording.json`, `Frames.csv`, `ZoneSpeeds.csv` and `Depth.bin` are equal. |
| FR-LINE-06 | If the video writer fails or is not ready for a frame, the depth frame and its metadata are still recorded. | Depth and metadata frame counts stay equal when video frames are skipped. |
| FR-LINE-07 | After Stop the recording is saved first and the scan is added to the library straight away (summary "<n> frames, <t> s, material travel <direction>", any "Recording stopped early: …" and video notes, "Map not built yet…"), then the camera stops, the map is built off the main thread (FR-TOPO-01…04), `TopoMap.png` is rendered, and the scan is updated with the map summary (or "Map not built: <reason>"); the scan opens. | The scan appears in the library and opens on its detail screen. |
| FR-LINE-08 | If no frame was recorded, "Recording not saved: no frames were recorded" is shown, the screen returns to Ready and the empty folder is removed. A recording with at least one frame is always kept (FR-LINE-12): if only the library entry cannot be written, the files stay in the folder and the library recovers them later (FR-LINE-14); if the map fails, the scan is saved with "Map not built: <reason>". | Stopping immediately after starting shows the message and leaves no folder. |
| FR-LINE-09 | Close is disabled while recording, saving or building the map. | Close is greyed out in those phases. |
| FR-LINE-10 | Handle backgrounding, capture-session interruptions, runtime errors and system (thermal) pressure during a recording: stop and save inside a background task and tell the user ("Recording stopped early: <reason>." in the scan summary; banners "Camera paused: …", "Camera error: …"). Serious pressure: banner "Phone is hot: live overlay slowed to reduce load…" and the live overlay refreshes every 6th frame instead of every 2nd; critical pressure stops and saves the recording and refuses a new one ("Recording not started: the phone is too hot…"). A runtime error restarts the camera (up to 3 times in a row; always after a media-services reset). A baseline calibration in progress is cancelled by backgrounding or an interruption. | Locking the phone or receiving a call mid-recording yields a saved, playable recording and a message. |
| FR-LINE-11 | Stop the recording and report on the first write error; check free storage before recording starts (refused below 1.0 GB free) and every 150 frames while recording (stop and save below 300 MB free). | With storage nearly full, Record is refused or the recording stops cleanly with a message. |
| FR-LINE-12 | Never delete a recording folder that holds recorded frames; save what exists and report the problem. | A forced metadata write failure leaves `Depth.bin`/`Video.mov` in place and visible. |
| FR-LINE-13 | Report a recorder start failure immediately and enter the recording state only when the recorder exists ("Recording not started: …", also when no camera frame arrives within 3 s). | A forced recorder failure shows an error instead of "● REC … 0 frames". |
| FR-LINE-14 | Recover line recordings that were never saved (app killed, crash, power loss): at library load, when the app becomes active and after a Line scan screen closes, a background pass repairs the cut-off `Recording.json` (complete frame lines kept) of every `line_` folder still carrying the recording marker and adds it as a scan named "Line <date> (recovered)" (summary says it was recovered and that the map is not built). Folders touched in the last 30 s and folders of a running recording are left alone; a failed recovery is reported once on Home and kept under Incomplete scans with the reason. The Incomplete scan screen offers **Recover recording** for such a folder. A recording that stopped normally but whose first `scan.json` save failed is recovered from the `.pending-scan.json` sidecar with its own name and summary (G-2); a repaired `Recording.json` keeps `"repaired": true`, so the "last frames may be missing" note survives rebuilds (G-5); a saved scan with an unreadable `Recording.json` is not reported as an incomplete scan (G-1). | Killing the app mid-recording and reopening it shows the recording under Saved scans, with a "Line recordings" notice on Home. |

### 5.6 Line scan calibration: baseline and level (FR-CAL)

| ID | Requirement | Acceptance criteria |
|---|---|---|
| FR-CAL-01 | Bubble level from gravity (CoreMotion device motion, 30 Hz): tiltX = asin(−g.x), tiltY = asin(−g.y) in degrees, + = right / top edge high for a screen-up phone. The bubble moves toward the high edge; rim = 3°; rings at 0.5° and 2° drawn at the same scale as the bubble travel; colour green ≤ 0.5°, yellow ≤ 2°, red above (combined tilt √(x² + y²)); readout "↔ x°  ↕ y°  (total)". | Raising the right edge moves the bubble right and makes ↔ positive. |
| FR-CAL-02 | Zero here / Re-zero stores the current gravity tilt as zero; Reset clears it. The zero persists in `UserDefaults` (`lineLevelZeroed`, `lineLevelZeroX`, `lineLevelZeroY`); the label reads "Phone vs zero" or "Phone vs gravity". | After Zero here the bubble is centred; the zero survives an app restart. |
| FR-CAL-03 | Every second frame a least-squares plane is fitted to the depth points (camera coordinates) and converted to the phone's tilt relative to the surface (same sign convention), shown as an orange ring and the "Phone vs surface (LiDAR)" readout. | Over a flat surface the ring sits near the bubble once the phone is level. |
| FR-CAL-04 | Baseline calibration (Ready phase): 90 frames; the first 60 give a per-pixel trimmed mean (middle half of the readings), a pixel needs ≥ 20 valid readings, valid pixels must cover ≥ 50 % of the view (below that the calibration is refused with "Calibration refused: only N % …"); remaining pixels are filled from a plane fit; the last 30 frames measure the corrected σ. Stored: mean distance, raw σ, P1–P99 range, corrected σ, coverage %, mean gravity tilt, filter mode, frame count, date. Progress bar during capture, "Building baseline…" while computing, a failure message otherwise. | Calibrating over an empty flat surface ends with the "Baseline set" banner and statistics. |
| FR-CAL-05 | The baseline is saved to `Documents/Calibration/` (`Baseline.bin`, `Baseline.json`), loaded when the Line scan screen opens, and can be recalibrated or cleared. The screen shows "<d> mm away · flat surface <σ> mm σ (<range> mm range) → <σc> mm σ corrected". | The baseline survives an app restart; Clear deletes both files. |
| FR-CAL-06 | Height mode: while a baseline of the current depth-map size is active, the overlay, legend (Low → High), flatness σ and centre height use height = baseline − distance (mm); dark blue = lowest, dark red = highest (P2–P98 range, minimum span 0.5 mm). | An object placed on the surface reads its height in mm. |
| FR-CAL-07 | Warnings (full text in the Ready phase; short forms stay visible while recording): "Phone tilt changed x° since calibration — recalibrate" when the gravity tilt differs from the calibration tilt by more than 0.3°; "Calibrated with filtered/raw depth — recalibrate for this setting" when the filter setting differs. | Tilting the mount by 0.5° shows the tilt warning. |
| FR-CAL-08 | Gravity and surface tilt are recorded per frame (`Recording.json`, `Frames.csv`); gravity tilt is shown during playback. | Tilt columns are filled in `Frames.csv`. |
| FR-CAL-09 | Depth-filter and shutter settings are locked while a baseline is being captured. | The toggles are disabled during calibration. |
| FR-CAL-10 | Show the baseline's valid coverage ("coverage N %"); warn below 80 % ("Only N % of the view had steady LiDAR readings; the rest is estimated from a fitted plane…"); refuse below 50 %. | A baseline over a partly non-reflective surface shows its coverage and a warning. |

### 5.7 Line scan speed (FR-SPD)

| ID | Requirement | Acceptance criteria |
|---|---|---|
| FR-SPD-01 | Main speed: block matching between consecutive video frames on a luma pyramid (1/8-scale coarse search, 1/2-scale refinement, parabolic sub-pixel), with a 0–1 match quality. Speed (mm/s) = along-travel shift (full-resolution px) × median LiDAR distance of the tracked area ÷ focal length (video px) ÷ frame interval. A reading exists only when quality ≥ 0.1 and 0.001 s < Δt < 1 s. Search range: just under 480 px per frame. Algorithm: [design §6.2](design.md#62-main-speed-template-matching). | Mean speed of a run at constant speed meets NFR-ACC-02 (P9 V2, V3). |
| FR-SPD-02 | Displayed speed = mean of the valid readings among the last 15 frames (needs ≥ 3; otherwise the current reading), in mm/s, m/min and ft/min; "no texture lock" when there is no reading; sparkline of the last 300 displayed values. | A blank surface shows "no texture lock". |
| FR-SPD-03 | Travel is integrated every frame from the current reading, else the last valid reading (0 if none since the session started or the last direction change; at Record a held speed and smoothing readings at most 2.0 s old are kept and older ones cleared, Z-1/Y-1); recorded travel is relative to the recording start. | `travel_mm` in `Frames.csv` starts at 0 and increases with the material. |
| FR-SPD-04 | Zone speeds: a 6 × 4 grid (6 across, 4 along the travel), 128 × 128 px templates, up to 320 px per frame, zones near the downstream edge matched backwards; zone quality ≥ 0.12; each zone scaled by its own median LiDAR distance. Live values are the mean of the last 15 frames (needs ≥ 4 readings). | On a uniform conveyor the 24 zone means agree with the main speed (P9 V10). |
| FR-SPD-05 | Fastest zone (largest absolute speed; the signed value is shown) is marked with an orange box; tapping the picture selects a point and shows "At point" speed for the zone under it; ✕ clears the point. | The marker follows the fastest object. |
| FR-SPD-06 | Changing the direction flips the tracking sign and resets the tracker, the zone history, the last valid speed, the smoothing buffer and the sparkline (travel keeps its value). | After switching to left → right, material moving right reads positive. |
| FR-SPD-07 | Each recorded frame stores the raw speed, along and across shift (px), quality, the 24 raw zone speeds and the fastest zone (`Recording.json`, `Frames.csv`, `ZoneSpeeds.csv`). | Columns are filled whenever the live view shows a reading. |
| FR-SPD-08 | Apply a user-entered scale correction (derived from a known speed or a measured length) to speeds and travel. | After entering a factor, recorded speeds and travel change by that factor. |

### 5.8 Playback and touch probe (FR-PLAY)

| ID | Requirement | Acceptance criteria |
|---|---|---|
| FR-PLAY-01 | Playback loads (off the main thread) `Recording.json` (a cut-off file is repaired), `Video.mov` (optional), `Depth.bin` (optional) and the recording's baseline (when its size matches). Views: Camera, Blend (default, opacity 0.6, slider), Depth; without a playable video only Depth is offered. Depth colour range = `TopoStats.json` colour range when its height mode matches, otherwise per frame (P2–P98). | Each view mode shows the expected layers. |
| FR-PLAY-02 | Transport: play/pause (restarts from 0 at the end), scrub slider with exact seeking, rate menu 0.1×, 0.25×, 0.5×, 1×, 2×. The picture updates from a 30 Hz time observer. | Scrubbing updates the video, overlay and readouts together. |
| FR-PLAY-03 | Per-frame readouts: speed (centred ±7-frame mean) in mm/s and m/min, frame index, median distance, travel, lock %, gravity tilt; speed-versus-time graph (0 to 1.1 × maximum) with a cursor. | Readouts match the `Frames.csv` row of the frame on screen. |
| FR-PLAY-04 | "Fastest on screen": the fastest ±7-frame zone mean at the current frame, with the orange marker. | Marker shown whenever zone data exists. |
| FR-PLAY-05 | Touch probe: touch or drag anywhere on the picture area (touches outside the picture snap to its nearest edge). Current = 3 × 3 median distance at the current frame (height mode: baseline 3 × 3 median − distance); position in mm right/left and above/below the optical centre; "Speed here" = ±7-frame mean of the zone under the probe. | Current value changes frame by frame while playing. |
| FR-PLAY-06 | When the finger lifts, the probe pixel is read in every frame off the main thread: minimum and maximum with their times (tap to seek), mean, std dev, range, valid/total frames, and a trace (≤ 600 points) with the playback cursor. ✕ removes the probe. | Tapping Min seeks to the frame where the minimum occurs. |
| FR-PLAY-07 | Detect a missing or unplayable `Video.mov`, tell the user ("No Video.mov in this recording: playing the depth frames only." / "Video.mov could not be played (…): playing the depth frames only."), switch to the Depth view and keep playback running on a display-link clock over the frame times. When `Video.mov` is shorter than the recording (a recovered recording keeps only complete 5 s fragments), the frames after its end play on the same clock without a notice. | Deleting `Video.mov` leaves depth playback working with a notice; a recording with a short video plays to its last frame. |

### 5.9 Topographic map and statistics (FR-TOPO)

| ID | Requirement | Acceptance criteria |
|---|---|---|
| FR-TOPO-01 | Stitching: every depth pixel with a finite baseline value (height mode) inside a border of max(2, min(W, H)/32) px is projected with the frame's intrinsics and its own distance into map coordinates (q along, x across, mm) using the frame's travel; readings in one cell are averaged (running mean and variance). Cell = max(2, ⌈largest depth-pixel footprint⌉) mm (the footprint uses the 99.5th-percentile depth that lands on the map, the outermost pixel used and the 95th-percentile surface tilt, so the cell is never smaller than one depth pixel anywhere in the frame), enlarged ×1.25 until the grid has ≤ 3,000,000 cells; row and column indices are floored. While stitching the grid is padded by 6 % of the across width on every side; the empty margin is trimmed afterwards, so the map, coverage, length and width describe the observed extent. Algorithm: [design §6.8](design.md#68-topographic-stitching). | A recording of a stationary flat surface yields a uniform map. |
| FR-TOPO-02 | With a baseline of matching size in the recording folder, values are heights (baseline − distance); otherwise distances from the camera. | `TopoStats.csv` row `values` reads `height_above_flat_baseline` or `distance_from_camera` accordingly. |
| FR-TOPO-03 | Statistics over cells with data: mean, variance, std dev, CV (distance mode only: blank in `TopoStats.csv`, absent in `TopoStats.json` and hidden on screen in height mode), min, max, range, P1, P5, median, P95, P99; across and along profile std dev and range; residual std dev after removing both profiles; repeat-reading noise; readings per cell; coverage (cells with data ÷ cells of the trimmed map); length × width (trimmed map); speed mean, std dev, min, max and % of frames with a speed; colour range P1–P99. Definitions: [design §6.9](design.md#69-map-statistics). | Values recomputed from `TopoMap.csv` match `TopoStats.csv` (to the printed precision). |
| FR-TOPO-04 | Outputs in the recording folder: `TopoMapGrid.png`, `TopoMap.csv`, `TopoGrid.bin`, `TopoStats.csv`, `TopoStats.json`, `TopoProfiles.json`, `AcrossProfile.csv`, `AlongProfile.csv`; and `TopoMap.png` (composite rendered off the main thread and staged with the others after Stop, on Rebuild map and on replay open — Z-5). All outputs are written under temporary names and renamed together once all succeeded. | All nine files exist after a successful build; a failed rebuild leaves the previous set intact. |
| FR-TOPO-05 | Map screen (loads off the main thread; a rebuild error is shown even when an older map is on screen; the old map stays visible while rebuilding): zoomable map (fit to height, pinch up to 20×, nearest-neighbour), legend, travel and leading-edge caption, statistics, variation components, profile charts (along profile thinned to ≤ 800 points; distance axis reversed so up = closer), speed and scan sections. | Screen matches `TopoStats.json`. |
| FR-TOPO-06 | Rebuild map re-runs the build from `Recording.json` (repaired first when cut off, noted in the summary) and rewrites all outputs. | Rebuild after deleting `TopoGrid.bin` recreates it. |
| FR-TOPO-07 | Map summary lines (size, cell, coverage; mean/σ/variance; range; profiles; residual, noise, readings per cell; speed, or "no texture lock" worded by the recorded travel — "map uses zero travel" or "map travel N mm comes from the speed held from before Record"; frames and duration as read back from `Recording.json`; colours) are stored in the scan summary at save; a failed summary update is reported (Home notice after Stop, message on Rebuild map, alert in the replay). | Summary shown on the scan screen. |
| FR-TOPO-08 | After Rebuild map, the scan's summary and file list are refreshed. | New or changed files appear in the scan's Files list immediately. |

### 5.10 Topographic replay (FR-RPL)

| ID | Requirement | Acceptance criteria |
|---|---|---|
| FR-RPL-01 | Opening the replay loads `Recording.json`; when `TopoGrid.bin` is missing it builds the map once (writing `TopoGrid.bin` and `TopoMap.png`) and refreshes the file list; failures show "Cannot replay this recording" with the reason. | A recording made before PR #8 replays after a one-time build. |
| FR-RPL-02 | Replay data: crop to rows holding ≥ 30 % of the fullest row's cells and to columns with data; order columns oldest → newest; without a baseline use relative height = median distance − distance (+ = closer); per frame, the reveal position is the material at the downstream edge of the LiDAR view (never decreasing); after the last frame a run-out at the mean travel speed of the last second (fallback: whole recording), raised so the run-out never exceeds 60 s, over 3 s when no speed above 1 mm/s was measured, so the whole map is revealed by the end of the replay. Algorithm: [design §6.10](design.md#610-replay-data-preparation). | At each moment only material whose readings were complete at that time is shown. |
| FR-RPL-03 | Clock driven by the display link (30–60 Hz); speed 0.1×–20× (menu presets 0.1, 0.25, 0.5, 1, 2, 4, 8, 16; logarithmic slider in settings); playback starts at 1× when the screen opens; restart, step ±1 recorded frame (1/30 s steps in the run-out), time slider. | At 1× replay time tracks wall time (NFR-PERF-05). |
| FR-RPL-04 | Display grid: cells averaged into square blocks so the window holds ≤ ~260 blocks along and ≤ 90 across (last block row narrower, not larger; rebuilt in the background when the block size changes); gaps between two measured blocks filled (across a column up to 3 blocks, along a row up to 8 blocks; no edge extension); optional 3 × 3 smoothing; only blocks whose whole length is complete are drawn. | Strip redraws without visible stutter (NFR-PERF-04). |
| FR-RPL-05 | 3D strip (orthographic, sheared view): newest complete line at the right edge with a black marker; window = 2 × strip width by default; surface coloured from target − 2 tolerances (blue) through target (green) to target + 2 tolerances (red); side walls coloured like the edge above; tolerance planes (pink upper, light-blue lower) visible only where no surface covers them; height axis (mm) and across axis (mm from the image centre line); Map mode = top view. | Visual check against the build guide's description. |
| FR-RPL-06 | Gestures: one-finger drag up/down = view angle (5°–90°) and left/right = side angle (±1.2) in 3D mode; pinch = zoom (0.5×–8×); double tap = reset view. | Gestures change the view within the stated limits. |
| FR-RPL-07 | Readouts: header (title; t of total; frame N of M; speed; "run-out after the last frame"; newest-line mean and its difference from target; window mean, std dev, min/max, % within ± tolerance, from the measured blocks only), refreshed ≤ 20 Hz while playing; along chart of column means with tolerance band and five completion-time labels; across panel with the newest line (red) and the last second's average (grey dashed), target and tolerance lines; colour bar labelled at target − 2 … + 2 tolerances. | Readouts change as the strip scrolls. |
| FR-RPL-08 | Settings sheet: speed; target and tolerance steppers (step = a 1/2/2.5/5 × 10ⁿ value near tolerance ÷ 5) with reset to the defaults (median and robust σ, rounded); window length 1–10 × width; height scale 0.15–2; smooth 3 × 3; tolerance planes; view mode; view angle; side angle; zoom; reset view. | Each control changes the strip immediately. |
| FR-RPL-09 | Save image brings the readouts up to the playhead, writes a PNG (strip snapshot, title, time and statistics line, colour bar, caption) as `TopoReplay_<t>s.png` in the scan folder, refreshes the scan's file list and opens the share sheet. | The PNG appears in the scan's Files list. |
| FR-RPL-10 | Layouts: landscape (strip with along chart and colour bar, across panel on the right) and portrait (stacked). | Rotating the phone switches the layout. |

### 5.11 Library, sharing, files and viewer (FR-LIB)

| ID | Requirement | Acceptance criteria |
|---|---|---|
| FR-LIB-01 | Scan screen: type and date; 3D model section (viewer, loaded off the main thread; "View in AR at real size" via Quick Look when the primary model is USDZ; "Retry reconstruction" for an Object scan without a model, or "Add the finished model" when a complete model exists but was not recorded); Line scan section (map, replay, playback); summary; measurements; files (each shareable; "Share photos" for `Images/`; "Share all files" when there is more than one); Files-app path in the footer; Rename (toolbar); Delete (with confirmation). | All sections appear for the matching scan types. |
| FR-LIB-02 | Rename trims whitespace and ignores empty names; Delete removes the folder and returns to Home. | Renamed scans keep their files; deleted scans vanish from Home and Files. |
| FR-LIB-03 | `Documents` is shared with the Files app (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`): `Scans/<folder>/` and `Calibration/` appear under On My iPhone › Phone LiDAR. | Files app shows the folders and files. |
| FR-LIB-04 | 3D viewer: USDZ through SceneKit; OBJ and PLY through ModelIO with a grey double-sided material; camera framed on the bounding sphere; orbit, zoom, pan; ruler mode measures between two tapped surface points (m and ft-in), with a list and Clear. Viewer measurements are not saved. | A known mesh distance reads the same as during capture (P9 V9). |
| FR-LIB-05 | Storage: one folder per scan with `scan.json`; the list is rebuilt from disk at launch and after every save, rename and delete; the folder name is taken from the directory; the file list = top-level regular files except `scan.json`, refreshed on every save. `scan.json` is decoded tolerantly (every field optional with a neutral default, unknown keys ignored, an unknown scan kind kept as read and written back unchanged on re-save); folder names are unique even within the same second; delete refuses folders that are not direct children of `Scans`. | A folder copied in with a valid `scan.json` appears after relaunch. |
| FR-LIB-06 | Share the Object Capture photos (`Images/`) from the scan screen. | A "Share photos" entry exports all photos. |
| FR-LIB-07 | List folders without a readable `scan.json` (incomplete scans) in an **Incomplete scans** section of Home so they can be shared or deleted (after confirmation); a folder a line recording is writing to is not listed; an interrupted line recording is titled "Interrupted recording" and offers **Recover recording** (FR-LINE-14). | An interrupted capture shows up under Incomplete scans. |

### 5.12 Export formats (FR-EXP)

Byte-level definitions are in [design.md §7](design.md#7-on-disk-formats). Each requirement means: the file is written exactly as specified there, and later readers (the app, Windows tools) can read it.

| ID | File(s) | Spec |
|---|---|---|
| FR-EXP-01 | `scan.json` (every scan) | §7.2 |
| FR-EXP-02 | CSV conventions shared by every CSV | §7.3 |
| FR-EXP-03 | `Room.usdz`, `RoomMesh.usdz`, `CapturedRoom.json`, `RoomReport.csv` | §7.4 |
| FR-EXP-04 | `Mesh.obj` | §7.5 |
| FR-EXP-05 | `Mesh.ply` (binary little-endian) | §7.5 |
| FR-EXP-06 | `Mesh.usdz` | §7.5 |
| FR-EXP-07 | `Measurements.csv` | §7.5 |
| FR-EXP-08 | `Model.usdz`, `Images/` | §7.6 |
| FR-EXP-09 | `Video.mov` | §7.7 |
| FR-EXP-10 | `Depth.bin` | §7.8 |
| FR-EXP-11 | `Recording.json` | §7.9 |
| FR-EXP-12 | `Frames.csv` | §7.10 |
| FR-EXP-13 | `ZoneSpeeds.csv` | §7.11 |
| FR-EXP-14 | `Baseline.bin`, `Baseline.json` | §7.12 |
| FR-EXP-15 | `TopoGrid.bin` | §7.13 |
| FR-EXP-16 | `TopoMap.csv` | §7.14 |
| FR-EXP-17 | `TopoStats.csv`, `TopoStats.json` | §7.15 |
| FR-EXP-18 | `AcrossProfile.csv`, `AlongProfile.csv`, `TopoProfiles.json` | §7.16 |
| FR-EXP-19 | `TopoMapGrid.png`, `TopoMap.png`, `TopoReplay_<t>s.png` | §7.17 |

### 5.13 Single-frame LiDAR map (FR-SFM)

The owner wants the scanned height of each passing strand, not values averaged between frames. These requirements add a map built from one reading per cell. Algorithm: [design §13](design.md#13-single-frame-lidar-map).

| ID | Requirement | Acceptance criteria |
|---|---|---|
| FR-SFM-01 | Line scan screen: **Map** setting *Averaged* / *Single frame (no averaging)*, before recording, stored in `Recording.json` as `mapMethod` (`averaged` / `singleReading`; absent = averaged). Choosing *Single frame* turns **Raw LiDAR depth** on, because Apple's filter smooths over time. | The setting is in `Recording.json`; raw depth is on after choosing Single frame. |
| FR-SFM-02 | Single-frame build: every cell takes exactly one depth reading: of all readings that land in the cell, the one whose depth row was closest to the scan line (the depth row nearest the principal point `cy`, where the view looks straight down); equal distances keep the earlier frame. No reading is averaged with another. | A cell's value equals one depth pixel of one frame (unit test). |
| FR-SFM-03 | Repeated depth frames: a frame in which ≥ 90 % of the pixels valid in both it and the previous frame are identical to the previous frame is a repeat of older laser data and is not used. The count is reported. | A synthetic recording with duplicated frames uses only the originals (unit test). |
| FR-SFM-04 | Outputs: the FR-TOPO-04 set plus `ScanLineProfiles.csv`: one row per frame (frame, time, travel, repeated flag), then, for each map row, the scan-row reading nearest the row centre (within half a cell; blank otherwise). | File present after a single-frame build; values match the scan row of each frame. |
| FR-SFM-05 | `TopoStats` records `mapMethod`. Single-frame maps: readings per cell = 1, repeat-reading noise blank in `TopoStats.csv` and "—" on screen; summary line "Map method: one reading per cell (no averaging) …" with frames used and repeated frames skipped. | Values in `TopoStats.csv`/`.json` and the summary. |
| FR-SFM-06 | Map screen: **Map method** picker and **Rebuild map** build either method from the same recording. Default = method of the map on screen, else the recording's `mapMethod`. The replay uses the map last built. | Rebuilding as Averaged and back as Single frame changes `TopoStats.json` `mapMethod` and the map. |

### 5.14 Laser line scan (FR-LAS)

Laser-line triangulation with the phone's main camera for strand-level topography. Algorithm and formats: [design §14](design.md#14-laser-line-scan).

| ID | Requirement | Acceptance criteria |
|---|---|---|
| FR-LAS-01 | Home: new scan mode **Laser line scan (flake topography)**, available on any iPhone with a back wide camera. | Row on Home; opens the laser screen. |
| FR-LAS-02 | Capture: back wide camera, 1920 × 1080 8-bit YUV (fallback 1280 × 720), frame rate 240 / 120 / 60 fps (default 240; the highest available when the requested one is not), video stabilisation off, auto-exposure with a shutter limit (1/1000 s default; 1/2000, 1/4000) and exposure bias, camera intrinsics per frame when available. Focus and white balance are locked when the baseline is calibrated; the locked lens position is saved and restored. | Readout shows the active fps and format; recorded `LaserRecording.json` holds them. |
| FR-LAS-03 | Line detection on the luma plane, every 2nd column: per column the brightest row in the search band; valid when it is ≥ 30 grey levels above the darkest value within ±12 rows; sub-pixel centre = centre of gravity of the contiguous pixels above half-height (max ±10 rows). Search band = baseline rows ± the shift of the maximum height setting (default 100 mm); full frame on every 4th frame until a baseline exists. | Synthetic Gaussian lines are found to ≤ 0.05 px for σ ≥ 2 px and ≤ 0.1 px for σ = 1.5 px (the half-height centre of gravity is biased toward whole pixels for narrower lines; unit tests). |
| FR-LAS-04 | Calibration: camera height H (lens to belt, mm; entered, or measured with the LiDAR); baseline on the empty belt (1 s; per-column median; ≥ 50 % of columns needed; gaps interpolated; coverage shown); height scale from a shim of known thickness under part of the line (preferred), else from the laser angle and side. Stored in *Calibration › LaserCalibration.json* and copied into every recording; used only with the same picture size, columns, intrinsics (f within 1 %, c within 3 px) and binning. | Calibration survives closing the screen; a recording holds its calibration. |
| FR-LAS-05 | Geometry: shift d = row − baseline row (px); height h = H·d / (A_k + d) with the per-column scale A_k = K + (baseline row − c_y) (px) and the signed laser term K from the calibration (shim: K = d_shim·(H − t)/t − (shim baseline row − c_y); angle: K = ±f_y·tan θ, + when the laser is on the left of the portrait screen); across x = (u − c_x)(H − h)/f_x; along y = (v − c_y)(H − h)/f_y. Readings with |A_k + d| < 1 px or h outside [−0.5 H, 0.8 H] are dropped. | Formula unit tests; a shim reads its thickness. |
| FR-LAS-06 | Speed and travel: `SpeedEstimator` on the rows of the frame away from the laser band (the larger side), every round(fps / 60)-th frame (≈ 60 Hz), only when that part has ≥ 216 rows (else a "No room for speed tracking" notice); mm per pixel from H minus the line's median height; travel at every frame = travel at the last tracked frame + held speed × elapsed time. | Travel unit test; live speed readout. |
| FR-LAS-07 | Recording: `scan.json` is written at Record (so a killed recording stays in the library), `LaserRecording.json` at Record and at Stop, `Profiles.bin` (raw sub-pixel line rows per frame) and `LaserFrames.csv` streamed. Stops and saves on background, camera interruption or error, critical heat, free storage < 300 MB or a write error; no start below 1 GB free. Captured data is never deleted on failure. | Files present after Stop; a stopped recording keeps its frames. |
| FR-LAS-08 | Map: heights above the belt; **single reading per cell** by default (the reading nearest the cell centre), *Averaged* selectable; cell = max(across column spacing at the belt, 90th-percentile travel per frame, 0.2 mm) rounded up to 0.1 mm, ×1.25 until ≤ 3,000,000 cells; outputs and summary as FR-TOPO-04/07. | Map files after Stop and after Rebuild map. |
| FR-LAS-09 | The map screen (statistics, method picker, rebuild) and the replay work for laser scans; the replay uses the tracked frames and reveals material at the laser line. | Both screens open a laser scan. |
| FR-LAS-10 | Live view: detected line (green) and baseline (yellow) over the picture, across height profile, speed, % of columns detected, median and maximum height on the line, actual fps and dropped frames. | Visible while previewing and recording. |
| FR-LAS-11 | Calibration method on the laser screen: **Empty belt** (baseline + shim or angle, FR-LAS-04) or **Side walls** (no clearing of the belt; design §14.9). | Picker; the stored calibration records `method`. |
| FR-LAS-12 | Side-wall calibration inputs: camera height H (Set or LiDAR), wall-top height h_w above the belt, laser angle θ from vertical (digital angle gauge) and its side; camera tilt along the travel φ from the gravity sensor (its own level zero, made on a level surface). K = f_y·tan(side·θ − φ); heights of angle scales with a tilt use the effective camera height H_eff = H·cos θ·cos β₀ / (cos(β₀ − φ)·cos(side·θ − φ)) per column (exact for a tilted camera). Walls = per-column median of 60 frames over ≈ 1 s; on each side the widest run of columns raised ≥ 10 px above the median of the middle half that reaches into the outer quarter; selection on median rows with the line's roll removed (slope from the two halves of the middle half; fit on measured rows); its level = the most raised flat window of 3 adjacent columns (spread ≤ 1.5 px, which excludes spikes; the lower inner face is never the level); plateau within 1 % of the wall's rise of it, 0.5–2 px (gaps ≤ 2 columns bridged), ≥ 3 columns (wall tops ≥ ≈ 12 mm wide at 3.3 m). Belt row of each wall column v₀ = (v_w − (K − c_y)·r)/(1 + r), r = h_w/(H − h_w); least-squares straight line through both walls = baseline of every column (flat belt). Refused unless both walls are found; fit residual shown; wall points drawn in orange; a new camera height refits from the stored wall rows; shim and angle actions are refused on a side-wall calibration; a camera tilt across the belt over 0.5° is flagged. The empty-belt angle path also uses φ and H_eff. | Synthetic walls give the tilted belt line and the mat height exactly, also for a ray-traced camera tilted 1–2° (unit tests). |
| FR-LAS-13 | Wall re-zero (side walls, on by default, switchable): per frame, per side the median of (row − calibration wall row) over its wall columns with a detection (≥ 2); both sides → straight-line shift of the baseline, one side → offset, none → last value held. Applied live and in every map build. Summary line "Wall re-zero: N % of frames measured, line shift a…b px (mean c px)". | A synthetic 3 px picture shift reads 0 mm with re-zero and 7.4 mm without (unit test). |
| FR-LAS-14 | With side walls the map keeps readings strictly between the walls' inner faces (10 mm margin), and the live median and maximum use the columns between the feet of the faces. | Map width excludes the walls (unit test). |
| FR-LAS-15 | Accuracy budget (flat belt, one wall height per side; analysis in design §14.9): worst case over 0–200 mm ≤ 2.5 mm with θ ±0.1°, H ±5 mm, h_w ±1 mm; ≤ 5.0 mm with θ ±0.2°, H ±10 mm, h_w ±2 mm (owner's tolerance 5 mm). | Unit test reproduces the 5.0 mm case; P9 V15 on the line. |

## 6. Non-functional requirements

Status values: **Met** (shown by the code or CI), **Partially met**, **Not met**, **Unverified** (a target that needs device measurement; the P9 test that measures it is named). Numbers marked UNVERIFIED come from the build guide's "expected performance" (published LiDAR measurements) or are proposed targets; none has been measured with this app.

### 6.1 Platform

| ID | Requirement | Measure / target | Status |
|---|---|---|---|
| NFR-PLAT-01 | iPhone only, iOS 17.0 or later; target device iPhone 17 Pro Max (iOS 26). Installation requires ARKit (`UIRequiredDeviceCapabilities` = `arkit`); capture modes additionally need LiDAR and are disabled otherwise (FR-APP-01). | `project.yml`: deployment target 17.0, `TARGETED_DEVICE_FAMILY` 1. | Met |
| NFR-PLAT-02 | Native Swift (Swift 5 language mode) with SwiftUI and Observation; UIKit, SceneKit, RealityKit, ARKit, RoomPlan, AVFoundation, CoreMotion, Charts, ModelIO; no third-party packages. | No package dependencies in `project.yml`. | Met |

### 6.2 Performance

| ID | Requirement | Measure / target | Status |
|---|---|---|---|
| NFR-PERF-01 | Line capture delivers synchronized depth + video at 30 fps; per-frame processing keeps up so frames are not systematically dropped (late frames are discarded, never queued). | Recorded frame intervals: median 33.3 ms ± 0.5 ms; ≥ 98 % of intervals < 50 ms over a 10-minute recording (P9 V1). | Unverified |
| NFR-PERF-02 | Live feedback: readouts every processed frame; depth overlay every second frame (≈ 15 Hz); displayed speed = 0.5 s average. | By construction (code). | Met (design); on-device rate Unverified (V1) |
| NFR-PERF-03 | Map build after Stop completes in "a few seconds" (build guide). | ≤ 10 s from Stop to the scan screen for a 60 s recording at ~1 m (P9 V6). Grid ≤ 3,000,000 cells. | Unverified |
| NFR-PERF-04 | Replay redraws at the display refresh: display link preferred 60 Hz (minimum 30), display grid ≤ ~260 × 90 blocks per window, readouts ≤ 20 Hz. | No visible stutter at 1× and 16× on the target device (P9 V7). | Unverified |
| NFR-PERF-05 | Replay timing follows recording time at the selected speed (clock step clamped to ≤ 0.1 s per refresh). | At 1×, replay time vs wall clock within ±1 % over 60 s; at 4×, ratio 4.00 ± 0.04 (P9 V7). | Unverified |
| NFR-PERF-06 | Playback stays responsive: the overlay updates per frame; whole-recording probe statistics are computed in parallel off the main thread. | Probe min/max appear ≤ 2 s after lifting the finger on a 60 s recording (P9 V4). | Unverified |
| NFR-PERF-07 | Sustained recording on USB-C power on a plant mount. A "Hot" label shows at serious/critical thermal state; at serious state the live overlay and LiDAR tilt refresh every 6th frame instead of every 2nd (recording continues), at critical state the recording is stopped and saved. | 10-minute recording completes; NFR-PERF-01 still met; no thermal shutdown (P9 V1). | Unverified |
| NFR-PERF-08 | Laser line scan: per-frame line detection, travel and recording keep up at 240 fps; frames dropped by the camera are counted, shown live and saved. | Dropped frames ≤ 2 % over a 60 s recording at 240 fps (P9 V13). | Unverified |

### 6.3 Measurement accuracy (all UNVERIFIED on device)

| ID | Requirement | Measure / target | Status |
|---|---|---|---|
| NFR-ACC-01 | Height above the baseline after averaging, at ~1 m: ±1–2 mm (build guide, expected performance). | Gauge plates of known thickness: error ≤ ±2 mm per plate (P9 V4). | Unverified |
| NFR-ACC-02 | Speed: ±0.2–0.3 % once the distance scale has been checked against a known speed or length (build guide). Uncorrected scale error is not specified by the guide. | Proposed: uncorrected mean-speed error ≤ 2 %; after one scale factor from the first run, later runs within ±0.3 % (P9 V2, V3). | Unverified |
| NFR-ACC-03 | Flatness after baseline correction on an empty flat surface. | Proposed: `Baseline.json` `correctedStdDev` ≤ 2.0 mm; map of an empty-surface recording: `height_std_dev` ≤ 1.0 mm and absolute `height_mean` ≤ 1.0 mm, so ±2σ ≤ 2 mm (P9 V5). | Unverified |
| NFR-ACC-04 | Room dimensions (RoomPlan). | Proposed: each wall length within ±2 % or ±5 cm (whichever is larger) of tape; wall height ±3 cm (P9 V8). | Unverified |
| NFR-ACC-05 | Equipment mesh point-to-point distances at 0.5–3 m. | Proposed: within ±1 cm or ±1 % (whichever is larger) of tape, live and in the viewer (P9 V9). | Unverified |
| NFR-ACC-06 | Map completeness and geometry. | Coverage ≥ 95 % for a run whose material fills the view (coverage is computed over the measured extent with the empty padding trimmed, B-4, and the cell is never smaller than a depth-pixel footprint, P-1, so a gap-free scan has no empty rows or columns); no missing columns along the run; across width within ±1 % of the tape width of a board (P9 V6). | Unverified |
| NFR-ACC-07 | Sampling limits stated by the build guide: ~15 real LiDAR samples per second (30 depth frames/s delivered), real laser-spot spacing ≈ 5 cm across at 1 m. Features smaller than the spot spacing are interpolated by the depth pipeline. | Informational; test pieces in P9 are ≥ 100 mm square. | Unverified |
| NFR-ACC-08 | Laser line height per single reading (no averaging), after shim calibration. | Proposed: shims and steps of 0.5–10 mm read within ±0.2 mm at 0.5 m and ±0.3 mm at 1 m camera height (P9 V12). | Unverified |
| NFR-ACC-09 | Single-frame LiDAR map: each value is one LiDAR reading; per-reading noise and the ≈ 5 cm spot spacing at 1 m are not reduced (NFR-ACC-07). | Informational; P9 V14 compares single-frame and averaged maps of one recording. | Unverified |

### 6.4 Reliability and data integrity

| ID | Requirement | Measure / target | Status |
|---|---|---|---|
| NFR-REL-01 | Recording integrity: a frame's metadata is appended only after its depth frame is written, so `Depth.bin` and the frame list stay in lock-step; video failure does not stop depth recording; readers stop cleanly at a truncated `Depth.bin` tail and the map uses `min(frames, depth frames)`. | Code inspection; P9 V1 checks equal counts. | Met |
| NFR-REL-02 | Metadata files (`scan.json`, JSON and most CSV outputs) are written atomically; a scan appears in the library only once its `scan.json` exists. | Code inspection. | Met |
| NFR-REL-03 | A crash, kill, backgrounding or capture interruption during a recording leaves a recoverable, playable recording. `Recording.json` (header first, one frame per line), `Frames.csv`, `ZoneSpeeds.csv` and `Depth.bin` are written as the recording runs, `Video.mov` in 5 s fragments, and a marker file flags the folder; backgrounding and interruptions stop and save; the library recovers killed recordings (FR-LINE-14). | Kill the app mid-recording: the data is recoverable. | Met by design and unit tests (A-1, A-3, F-6); on-device Unverified |
| NFR-REL-04 | Failures never delete captured data: a recording folder with frames and the Object Capture photos are kept (only empty folders are removed); delete needs confirmation. | Forced failures keep the data. | Met by design (A-2, C-2, C-8); on-device Unverified |
| NFR-REL-05 | Files written by older builds stay readable: new persisted `Codable` fields are optional (`tileSpeeds`, tilt fields, `tileColumns`/`tileRows`, `heightMode`); the replay builds `TopoGrid.bin` for older recordings. | Code inspection; recordings from PR #2 onward open. | Met |
| NFR-REL-06 | Write errors during capture are detected and reported (no silent frame loss): the first failed write stops the recording, which is saved with what it has. | Forced write failure is reported. | Met by design (A-2); on-device Unverified |

### 6.5 Storage and memory

| ID | Requirement | Measure / target | Status |
|---|---|---|---|
| NFR-STO-01 | All data is stored locally under the app's `Documents` (layout in [design §8](design.md#8-storage-layout)) and is reachable from the Files app. | Code inspection. | Met |
| NFR-STO-02 | Data volume of a line recording: video 16 Mbit/s ≈ 120 MB per minute; depth LZFSE-compressed from W × H × 2 bytes per frame (≈ 4.6 MB/s raw at an assumed 320 × 240, compression ratio unmeasured); `Recording.json` ≈ 1 kB per frame (compact, one line per frame; size unmeasured). Free space is checked before recording (≥ 1.0 GB) and every 150 frames (stop below 300 MB, FR-LINE-11). | Measure MB per minute on device (P9 V1). | Partially met (volume unmeasured) |
| NFR-STO-03 | Bounded memory in processing: map grid ≤ 3,000,000 cells (≈ 30 MB of arrays); `TopoMapGrid.png` width ≤ 12,000 px; probe trace ≤ 600 points; replay window ≤ ~260 × 90 blocks. Per-frame metadata of a recording is streamed to disk (A-3), so memory does not grow with its length. | Code inspection. | Met |

### 6.6 Usability

| ID | Requirement | Measure / target | Status |
|---|---|---|---|
| NFR-USE-01 | Fixed-mount use: speed readable at arm's length (42 pt bold); 72 pt record button; Close disabled while busy; screen awake for the whole time the Line scan screen is open (mounting, levelling, calibration, recording; P-6), and on the Room, Equipment and Object capture screens. | Owner check on the mount. | Met (design); owner check Unverified |
| NFR-USE-02 | Use with gloves and in poor light: primary actions ≥ 44 × 44 pt; readouts on dark translucent panels over the camera picture. Several secondary controls (Zero here, Reset, Recalibrate, Clear, ✕) are caption-size buttons. | Owner check with work gloves (capacitive) on the target device. | Partially met |
| NFR-USE-03 | Units: metric first with imperial alongside (ft-in for lengths, ft² for area, ft/min for speed); numbers use a "." decimal separator in files. | Code inspection. | Met |
| NFR-USE-04 | Orientation per FR-APP-04; recording screen and playback in portrait matching the mount. | Code inspection. | Met |
| NFR-USE-05 | Key controls carry accessibility labels (record, clear point, remove probe, replay transport, save image, settings). | Code inspection. | Partially met |

### 6.7 Maintainability and testability

| ID | Requirement | Measure / target | Status |
|---|---|---|---|
| NFR-MNT-01 | Warning-free build; one folder per module (`App`, `Room`, `Mesh`, `Object`, `Line`, `Viewer`, `Library`, `Storage`); pure logic separated from device-only code; doc comments on non-obvious code; units in names or comments. | CI build log: 0 warnings. | Met |
| NFR-MNT-02 | Requirements, design, plan, change log, `CLAUDE.md`, the user guide (`README.md`) and `REVISIONS.md` are kept current with every change. | Definition of done in the plan. | Partially met (docs aligned in P8; `REVISIONS.md` and the owner copy follow the merge) |
| NFR-TST-01 | Pure logic (formats, statistics, speed estimation on synthetic images, baseline maths, replay preparation, formatting) is unit-tested in a host-less XCTest bundle on the iOS Simulator, and CI runs the tests for every pull request. | CI `unit-tests` job green (all tests in the host-less `PhoneLidarTests` bundle; also runs for pull requests). | Met on `process-alignment`; on `main` after the merge |
| NFR-TST-02 | Device behaviour and accuracy are validated with documented on-device procedures and recorded results. | P9 tests V1–V10 recorded. | Not met (P9) |

### 6.8 Security and privacy

| ID | Requirement | Measure / target | Status |
|---|---|---|---|
| NFR-SEC-01 | The app requests only the permissions it uses: camera (with purpose string). No microphone, location or photo-library read. Photo-library add (`NSPhotoLibraryAddUsageDescription`) is declared for the share sheet's "Save Image/Video" (FR-APP-07). | `Info.plist`. | Met |
| NFR-SEC-02 | Local-only: no network code, analytics, logging services or accounts; data leaves the phone only by explicit user action (share sheet, AR Quick Look, Files app). | Source contains no networking APIs. | Met |
| NFR-SEC-03 | Public repository hygiene: no secrets, Apple IDs, keys, certificates, provisioning profiles, personal data, plant imagery or scan data in git; TestFlight credentials only as GitHub Actions secrets; `.gitignore` excludes build products and secret-file patterns. | Repo review; secret patterns in `.gitignore` (C-10). | Met |
| NFR-SEC-04 | Data at rest uses iOS default data protection for the app container; scans are visible to anyone with the unlocked phone via the Files app. Recordings may show people or equipment; the owner decides what to share. | Informational. | Met (as designed) |
| NFR-SEC-05 | CI workflow follows least privilege: explicit `permissions`, secrets scoped to the steps that need them, pinned actions and tools. | Workflow review (C-9, C-9r, E-1): `permissions: contents: read`, secrets only on the steps that use them, actions pinned to commit SHAs, XcodeGen pinned to a checksummed release zip, `codemagic-cli-tools` pinned, TestFlight job after build and tests. | Met |

### 6.9 Build and distribution

| ID | Requirement | Measure / target | Status |
|---|---|---|---|
| NFR-BLD-01 | Builds run only on GitHub Actions (`macos-26`, Xcode 26.x); XcodeGen generates the project from `project.yml`; no `.xcodeproj` in git; build number = workflow run number. | Workflow `Build iOS app`. | Met |
| NFR-BLD-02 | Distribution: unsigned `.ipa` artifact (`PhoneLidar-unsigned-ipa-<run>`, kept 30 days) for Sideloadly with a free Apple ID (re-sign every 7 days); optional TestFlight job (manual, four secrets, `codemagic-cli-tools`). | Artifacts on each run. | Met |
| NFR-BLD-03 | CI diagnostics: compile errors on the run summary page; `build-log-<run>` artifact (14 days); the run summary shows the warning count, the failed tests and the compile errors; any compiler warning fails the build job and the test job; the unit-test results artifact (`.xcresult`, logs) is kept 14 days when tests fail. | Run summary. | Met |

## 7. Constraints and assumptions

| ID | Constraint / assumption |
|---|---|
| CON-01 | No Mac is available. The Linux workspace has no Swift toolchain; code cannot be compiled or run locally. CI is the only compiler. |
| CON-02 | LiDAR, RoomPlan, ARKit scene reconstruction, Object Capture and the AVFoundation LiDAR depth camera work only on a physical LiDAR iPhone; the simulator runs pure logic only. |
| CON-03 | The Xcode project is generated by XcodeGen; `project.yml` is the source of truth for targets and settings. |
| CON-04 | Distribution without the App Store: Sideloadly with a free Apple ID (7-day signing, 3 apps, 10 App IDs per 7 days) or TestFlight with a paid developer account (90-day builds). |
| CON-05 | The repository is public: nothing secret or personal may be committed. Look-reference media (`Reference/`) stays in the owner's local folder. |
| CON-06 | Builds stay warning-free. |
| CON-07 | Existing on-disk formats stay readable by new builds; incompatible changes need a version bump and a migration path. |
| ASM-01 | The video and depth streams share the same field of view (4:3 formats), so normalized image regions map between them. |
| ASM-02 | The surface below a line-scan mount is roughly perpendicular to the camera axis and moves as a rigid body along the buffer rows; travel is integrated from texture motion only (no encoder input). |
| ASM-03 | The depth intrinsics from `AVCameraCalibrationData` (or the field-of-view fallback) describe a pinhole camera; lens distortion is not corrected. |
| ASM-04 | Phone and mount stay still between baseline calibration and recording; the tilt warning (> 0.3°) is the only movement check. |
| ASM-05 | The owner moves data to Windows by share sheet or Files app and analyses CSV/binary files with desktop tools. |

## 8. Traceability

Paths are relative to `PhoneLidar/`. Status legend in §4. Review IDs name the M1 cycle-1 finding that tracks a gap.

| Requirement | Source files | Status |
|---|---|---|
| FR-APP-01 | App/HomeView.swift; Line/LineCapturePipeline.swift (`isSupported`) | Implemented – not verified on device |
| FR-APP-02 | App/HomeView.swift | Implemented – not verified on device |
| FR-APP-03 | App/HomeView.swift (confirmation dialog); Storage/ScanStore.swift (`delete`, `deleteIncomplete`) | Implemented – not verified on device |
| FR-APP-04 | App/OrientationLock.swift; App/PhoneLidarApp.swift; Line/TopoReplayView.swift; Support/Info.plist | Implemented – not verified on device |
| FR-APP-05 | Support/Info.plist | Implemented – not verified on device |
| FR-APP-06 | App/CameraAccess.swift (`CameraAccess`, `CameraDeniedView`); Room/RoomScanView.swift; Mesh/MeshScanView.swift; Object/ObjectScanView.swift; Line/LineScanView.swift (A-9, C-5) | Implemented – not verified on device |
| FR-APP-07 | Support/Info.plist (`NSPhotoLibraryAddUsageDescription`, C-1) | Implemented – not verified on device |
| FR-ROOM-01 | Room/RoomScanView.swift | Implemented – not verified on device |
| FR-ROOM-02 | Room/RoomScanView.swift | Implemented – not verified on device |
| FR-ROOM-03 | Room/RoomScanView.swift | Implemented – not verified on device |
| FR-ROOM-04 | Room/RoomReport.swift; Storage/Formatting.swift | Implemented |
| FR-ROOM-05 | Room/RoomReport.swift; Storage/Formatting.swift | Implemented |
| FR-ROOM-06 | Room/RoomScanView.swift | Implemented – not verified on device |
| FR-ROOM-07 | Room/RoomReport.swift; Storage/Formatting.swift (`CSV.roomSummary`; unit tests; C-16, E-4) | Implemented – not verified on device |
| FR-MESH-01 | Mesh/MeshScanView.swift | Implemented – not verified on device |
| FR-MESH-02 | Mesh/MeshScanView.swift (crosshair offset: C-3) | Implemented – not verified on device |
| FR-MESH-03 | Mesh/MeshScanView.swift | Implemented – not verified on device |
| FR-MESH-04 | Mesh/MeshScanView.swift; Mesh/MeshExporter.swift | Implemented – not verified on device |
| FR-MESH-05 | Mesh/MeshScanView.swift; Storage/Formatting.swift | Implemented |
| FR-OBJ-01 | Object/ObjectScanView.swift | Implemented – not verified on device |
| FR-OBJ-02 | Object/ObjectScanView.swift | Implemented – not verified on device |
| FR-OBJ-03 | Object/ObjectScanView.swift | Implemented – not verified on device |
| FR-OBJ-04 | Object/ObjectScanView.swift | Implemented – not verified on device |
| FR-OBJ-05 | Object/ObjectScanView.swift (`keepPhotos`, `retry`, `retrySave`, `ObjectPhotos.hasCompleteModel`); Library/ScanDetailView.swift (C-2, E-2, G-3, G-7) | Implemented – not verified on device |
| FR-OBJ-06 | Object/ObjectScanView.swift | Implemented – not verified on device |
| FR-OBJ-07 | App/KeepScreenOn.swift; Object/ObjectScanView.swift; Room/RoomScanView.swift; Mesh/MeshScanView.swift (C-4) | Implemented – not verified on device |
| FR-LINE-01 | Line/LineCapturePipeline.swift | Implemented – not verified on device |
| FR-LINE-02 | Line/LineScanView.swift; Line/LineCapturePipeline.swift; Line/DepthColors.swift | Implemented – not verified on device |
| FR-LINE-03 | Line/LineScanView.swift; Line/LineCapturePipeline.swift | Implemented – not verified on device |
| FR-LINE-04 | Line/LineScanView.swift; Line/LineCapturePipeline.swift (`applyShutter`, A-7) | Implemented – not verified on device |
| FR-LINE-05 | Line/LineScanView.swift; Line/LineCapturePipeline.swift; Line/LineRecording.swift (`LineRecorder`, `RecordingJSONWriter`, `TextFileWriter`); Line/Baseline.swift (A-1, A-3, P-6) | Implemented – not verified on device |
| FR-LINE-06 | Line/LineRecording.swift | Implemented – not verified on device |
| FR-LINE-07 | Line/LineScanView.swift; Line/TopoMapBuilder.swift; Line/TopoMapRenderer.swift | Implemented – not verified on device |
| FR-LINE-08 | Line/LineScanView.swift; Line/LineCapturePipeline.swift; Line/LineRecording.swift | Implemented – not verified on device |
| FR-LINE-09 | Line/LineScanView.swift | Implemented – not verified on device |
| FR-LINE-10 | Line/LineScanView.swift (`scenePhaseChanged`, `stop`); Line/LineCapturePipeline.swift (interruption, runtime error, pressure observers) (A-1, A-4, D-2) | Implemented – not verified on device |
| FR-LINE-11 | Line/LineRecording.swift (`LineStorage`, `LineRecorder.append`); Line/LineScanView.swift (A-2) | Implemented – not verified on device |
| FR-LINE-12 | Line/LineScanView.swift (`recordingStopped`); Line/LineRecording.swift (A-2) | Implemented – not verified on device |
| FR-LINE-13 | Line/LineCapturePipeline.swift (`startRecording`); Line/LineScanView.swift (A-5) | Implemented – not verified on device |
| FR-LINE-14 | Line/LineRecordingRecovery.swift (`LineRecordingRepair`, `LineRecordingRecovery`, `ScanStore.recoverLineRecordings`); Library/IncompleteScanView.swift; App/HomeView.swift; Line/LineScanView.swift (sidecar) (F-6, D-6, D-7, G-1, G-2, G-5; unit tests for repair and recovery) | Implemented – not verified on device |
| FR-CAL-01 | Line/LineScanView.swift (`BubbleLevel`); Line/LineCapturePipeline.swift | Implemented – not verified on device |
| FR-CAL-02 | Line/LineScanView.swift | Implemented – not verified on device |
| FR-CAL-03 | Line/LineMotionMath.swift (`surfaceTilt`, unit-tested); Line/LineCapturePipeline.swift; Line/LineScanView.swift | Implemented – not verified on device |
| FR-CAL-04 | Line/Baseline.swift (`build`); Line/LineCapturePipeline.swift; Line/LineScanView.swift | Implemented – not verified on device |
| FR-CAL-05 | Line/Baseline.swift; Line/LineScanView.swift | Implemented – not verified on device |
| FR-CAL-06 | Line/LineCapturePipeline.swift; Line/Baseline.swift; Line/DepthColors.swift | Implemented – not verified on device |
| FR-CAL-07 | Line/LineScanView.swift | Implemented – not verified on device |
| FR-CAL-08 | Line/LineCapturePipeline.swift; Line/LineRecording.swift; Line/LinePlaybackView.swift | Implemented – not verified on device |
| FR-CAL-09 | Line/LineScanView.swift (A-6) | Implemented – not verified on device |
| FR-CAL-10 | Line/Baseline.swift (`minimumCoveragePercent` 50, `goodCoveragePercent` 80; unit tests); Line/LineScanView.swift (A-8) | Implemented – not verified on device |
| FR-SPD-01 | Line/SpeedEstimator.swift; Line/LineCapturePipeline.swift; Line/LineMotionMath.swift (Z-7, unit-tested) | Implemented – not verified on device |
| FR-SPD-02 | Line/LineCapturePipeline.swift; Line/LineMotionMath.swift; Line/LineScanView.swift; Line/LineRecording.swift (`SpeedText`) | Implemented – not verified on device |
| FR-SPD-03 | Line/LineCapturePipeline.swift; Line/LineMotionMath.swift; Line/LineRecording.swift (Z-1, Y-1, Z-9 tests) | Implemented – not verified on device |
| FR-SPD-04 | Line/SpeedEstimator.swift (`matchTiles`); Line/LineCapturePipeline.swift; Line/LineMotionMath.swift | Implemented – not verified on device |
| FR-SPD-05 | Line/LineScanView.swift; Line/LineRecording.swift (`ZoneGrid`) | Implemented – not verified on device |
| FR-SPD-06 | Line/LineCapturePipeline.swift; Line/LineMotionMath.swift; Line/LineScanView.swift | Implemented – not verified on device |
| FR-SPD-07 | Line/LineCapturePipeline.swift; Line/LineRecording.swift | Implemented – not verified on device |
| FR-SPD-08 | — (GC-10; backlog P10) | Not implemented |
| FR-PLAY-01 | Line/LinePlaybackView.swift; Line/Baseline.swift; Line/LineRecording.swift | Implemented – not verified on device |
| FR-PLAY-02 | Line/LinePlaybackView.swift | Implemented – not verified on device |
| FR-PLAY-03 | Line/LinePlaybackView.swift; Line/LineRecording.swift (`LineMath`) | Implemented – not verified on device |
| FR-PLAY-04 | Line/LinePlaybackView.swift; Line/LineCapturePipeline.swift (`fastest`) | Implemented – not verified on device |
| FR-PLAY-05 | Line/LinePlaybackView.swift; Line/LineRecording.swift (`DepthFileReader.sample`, `ZoneGrid`) | Implemented – not verified on device |
| FR-PLAY-06 | Line/LinePlaybackView.swift (`finishProbe`, `ProbeStats`) | Implemented – not verified on device |
| FR-PLAY-07 | Line/LinePlaybackView.swift (`videoNotice`, `videoFailed`, `videoReachedEnd`, frame-time clock) (B-6, F-3, E-3) | Implemented – not verified on device |
| FR-TOPO-01 | Line/TopoMapBuilder.swift (`pixelFootprint`, padding trim; unit tests) | Implemented |
| FR-TOPO-02 | Line/TopoMapBuilder.swift; Line/Baseline.swift | Implemented |
| FR-TOPO-03 | Line/TopoMapBuilder.swift | Implemented |
| FR-TOPO-04 | Line/TopoMapBuilder.swift; Line/TopoGridFile.swift; Line/TopoMapRenderer.swift | Implemented |
| FR-TOPO-05 | Line/TopoMapView.swift | Implemented – not verified on device |
| FR-TOPO-06 | Line/TopoMapView.swift | Implemented – not verified on device |
| FR-TOPO-07 | Line/TopoMapBuilder.swift (`summaryLines`); Line/LineScanView.swift | Implemented |
| FR-TOPO-08 | Line/TopoMapView.swift (`updateScanRecord`); Line/TopoReplayView.swift; Line/TopoMapBuilder.swift (`recordSummary`) (B-14) | Implemented – not verified on device |
| FR-RPL-01 | Line/TopoReplayView.swift; Line/TopoGridFile.swift; Line/TopoMapBuilder.swift | Implemented – not verified on device |
| FR-RPL-02 | Line/TopoReplayData.swift (`TopoReplaySource`; unit tests) | Implemented |
| FR-RPL-03 | Line/TopoReplayModel.swift; Line/TopoReplayView.swift | Implemented – not verified on device |
| FR-RPL-04 | Line/TopoReplayData.swift (`TopoDisplayGrid`; unit tests); Line/TopoReplayModel.swift | Implemented |
| FR-RPL-05 | Line/TopoReplayScene.swift; Line/TopoReplayData.swift (`ReplayPalette`) | Implemented – not verified on device |
| FR-RPL-06 | Line/TopoReplayView.swift | Implemented – not verified on device |
| FR-RPL-07 | Line/TopoReplayModel.swift; Line/TopoReplayView.swift | Implemented – not verified on device |
| FR-RPL-08 | Line/TopoReplayView.swift (`ReplaySettingsView`); Line/TopoReplayModel.swift | Implemented – not verified on device |
| FR-RPL-09 | Line/TopoReplayModel.swift (`saveImage`); Line/TopoReplayView.swift | Implemented – not verified on device |
| FR-RPL-10 | Line/TopoReplayView.swift | Implemented – not verified on device |
| FR-LIB-01 | Library/ScanDetailView.swift | Implemented – not verified on device |
| FR-LIB-02 | Library/ScanDetailView.swift; Storage/ScanStore.swift | Implemented – not verified on device |
| FR-LIB-03 | Support/Info.plist; Storage/ScanStore.swift; Line/Baseline.swift | Implemented – not verified on device |
| FR-LIB-04 | Viewer/ModelViewer.swift | Implemented – not verified on device |
| FR-LIB-05 | Storage/ScanStore.swift (tolerant `ScanRecord` decoding, unique folder names; unit tests) | Implemented |
| FR-LIB-06 | Library/ScanDetailView.swift; Storage/ScanStore.swift (`entries(inFolderNamed:)`) (C-18) | Implemented – not verified on device |
| FR-LIB-07 | Storage/ScanStore.swift (`incomplete`, `IncompleteScan`); App/HomeView.swift; Library/IncompleteScanView.swift (C-12) | Implemented – not verified on device |
| FR-EXP-01 | Storage/ScanStore.swift | Implemented |
| FR-EXP-02 | Storage/Formatting.swift (`CSV`); Line/LineRecording.swift (`TextFileWriter`) | Implemented |
| FR-EXP-03 | Room/RoomScanView.swift; Room/RoomReport.swift; Storage/Formatting.swift | Implemented – not verified on device (USDZ/JSON from RoomPlan); RoomReport.csv Implemented |
| FR-EXP-04 | Mesh/MeshExporter.swift | Implemented |
| FR-EXP-05 | Mesh/MeshExporter.swift | Implemented |
| FR-EXP-06 | Mesh/MeshExporter.swift | Implemented – not verified on device |
| FR-EXP-07 | Storage/Formatting.swift; Mesh/MeshScanView.swift | Implemented |
| FR-EXP-08 | Object/ObjectScanView.swift | Implemented – not verified on device |
| FR-EXP-09 | Line/LineRecording.swift (`LineRecorder`) | Implemented – not verified on device |
| FR-EXP-10 | Line/LineRecording.swift (`DepthFileWriter`, `DepthFileReader`) | Implemented |
| FR-EXP-11 | Line/LineRecording.swift (`RecordingJSONWriter`); Line/LineRecordingRecovery.swift (`LineRecordingRepair`) | Implemented |
| FR-EXP-12 | Line/LineRecording.swift (`LineRecorder.framesRow`) | Implemented |
| FR-EXP-13 | Line/LineRecording.swift (`LineRecorder.zonesRow`) | Implemented |
| FR-EXP-14 | Line/Baseline.swift | Implemented |
| FR-EXP-15 | Line/TopoGridFile.swift | Implemented |
| FR-EXP-16 | Line/TopoMapBuilder.swift (`writeGridCSV`) | Implemented |
| FR-EXP-17 | Line/TopoMapBuilder.swift (`statsCSV`) | Implemented |
| FR-EXP-18 | Line/TopoMapBuilder.swift (`profileCSV`) | Implemented |
| FR-EXP-19 | Line/TopoMapBuilder.swift; Line/TopoMapRenderer.swift (`compositePNG`); Line/TopoReplayModel.swift | Implemented |
| FR-SFM-01 | Line/LineScanView.swift; Line/LineCapturePipeline.swift; Line/LineRecording.swift (`mapMethod`) | Implemented – not verified on device |
| FR-SFM-02 | Line/MapCells.swift; Line/TopoMapBuilder.swift | Implemented |
| FR-SFM-03 | Line/MapCells.swift (`ScanLineMath`); Line/TopoMapBuilder.swift | Implemented |
| FR-SFM-04 | Line/TopoMapBuilder.swift (`scanLineProfilesCSV`) | Implemented |
| FR-SFM-05 | Line/TopoMapBuilder.swift; Line/TopoMapView.swift | Implemented |
| FR-SFM-06 | Line/TopoMapView.swift; Line/MapRebuild.swift | Implemented – not verified on device |
| FR-LAS-01 | App/HomeView.swift; Storage/ScanStore.swift (`ScanKind.laser`); Laser/LaserCapturePipeline.swift (`isSupported`) | Implemented – not verified on device |
| FR-LAS-02 | Laser/LaserCapturePipeline.swift | Implemented – not verified on device |
| FR-LAS-03 | Laser/LaserLineDetector.swift | Implemented |
| FR-LAS-04 | Laser/LaserGeometry.swift; Laser/LaserScanView.swift; Laser/LidarDistanceProbe.swift | Implemented – not verified on device |
| FR-LAS-05 | Laser/LaserGeometry.swift | Implemented |
| FR-LAS-06 | Laser/LaserGeometry.swift (`LaserTravel`); Laser/LaserCapturePipeline.swift; Line/SpeedEstimator.swift (`rows`) | Implemented – not verified on device |
| FR-LAS-07 | Laser/LaserRecording.swift; Laser/LaserCapturePipeline.swift; Laser/LaserScanView.swift | Implemented – not verified on device |
| FR-LAS-08 | Laser/LaserMapBuilder.swift; Line/MapCells.swift; Line/TopoMapBuilder.swift (`finish`) | Implemented |
| FR-LAS-09 | Line/TopoMapView.swift; Line/TopoReplayView.swift; Line/MapRebuild.swift; Line/TopoReplayData.swift | Implemented – not verified on device |
| FR-LAS-10 | Laser/LaserScanView.swift | Implemented – not verified on device |
| FR-LAS-11 | Laser/LaserGeometry.swift (`LaserCalibration.method`); Laser/LaserScanView.swift | Implemented – not verified on device |
| FR-LAS-12 | Laser/LaserWalls.swift; Laser/LaserScanModel.swift (`calibrateOnWalls`, level) | Implemented – not verified on device |
| FR-LAS-13 | Laser/LaserWalls.swift (`shift`); Laser/LaserMapBuilder.swift; Laser/LaserCapturePipeline.swift | Implemented |
| FR-LAS-14 | Laser/LaserWalls.swift (`isInsideWalls`, `matColumns`); Laser/LaserMapBuilder.swift; Laser/LaserCapturePipeline.swift | Implemented |
| FR-LAS-15 | Tests/PhoneLidarTests/LaserWallsTests.swift (`testFiveMillimetreBudget`) | Analysis verified; not verified on device |

## 9. Document history

| Date | Change |
|---|---|
| 2026-11-12 | P12: side-wall calibration and wall re-zero (FR-LAS-11…15). |
| 2026-11-12 | P11: single-frame LiDAR map (FR-SFM-01…06), laser line scan (FR-LAS-01…10), NFR-PERF-08, NFR-ACC-08/09. |
| 2026-11-10 | Updated for the M1 review fixes (cycles 1–2, on `process-alignment` `547de8c`): recovery of killed recordings (FR-LINE-14), incomplete scans, delete confirmation, baseline coverage thresholds, short-shutter exposure limit, trimmed map extent and cell sizing, CV in distance mode only, replay run-out, gap fill and measured-only statistics, playback without or with a short video, RoomReport totals block, Object photos kept, camera-permission handling, Photos permission. Items that were *Not implemented* moved to *Implemented – not verified on device*; NFR statuses refreshed. |
| 2026-11-10 | First version, reconstructed from the code at `1cf693e` and the build guide (P8 process alignment). Gaps cross-referenced to the M1 cycle-1 review findings. |
