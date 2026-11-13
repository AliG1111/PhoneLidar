# Phone LiDAR — iPhone LiDAR scanner built without a Mac

You need a Windows PC, a LiDAR iPhone (12 Pro / Pro Max or a newer **Pro** model, iOS 17+), a USB cable and a free GitHub account. The app is compiled on Apple hardware rented by GitHub Actions (`macos-26` runner with Xcode 26).

**Status (Nov 11, 2026):** the code is at github.com/AliG1111/PhoneLidar (public). This version adds the M1 review fixes, unit tests in CI and the developer docs (build #61, `PhoneLidar-unsigned-ipa-61`). It builds on build #23: the **Line scan** mode with baseline calibration, bubble level, local speeds (fastest on screen, speed at a point), playback touch probe and the **Topographic replay** (real-time scrolling 3D strip, 0.1×–20×). Step 1 is done. Start at Step 2 or Step 3.

## What the app does

| Mode | Apple framework | Output files |
|---|---|---|
| **Room scan** | RoomPlan | `Room.usdz` (walls/doors/windows/furniture as boxes), `RoomMesh.usdz`, `CapturedRoom.json`, `RoomReport.csv` (every wall, door, window, opening, floor and object with W × H × D in m and ft-in, plus a totals block: wall count, total wall length, maximum wall height, floor area) |
| **Equipment scan (LiDAR mesh)** | ARKit scene reconstruction | `Mesh.usdz`, `Mesh.obj`, `Mesh.ply` (world-space, metres, Y up), `Measurements.csv` from live point-to-point measuring |
| **Object capture** | RealityKit Object Capture + on-device photogrammetry | `Model.usdz` (photo-textured, real scale), `Images/` folder with the source photos (kept even when the model cannot be built) |
| **Line scan (moving material)** | AVFoundation LiDAR depth camera + synchronized video | `Video.mov`, `Depth.bin`, `Recording.json`, `Frames.csv` (per-frame speed, fastest zone, travel, distance, tilt), `ZoneSpeeds.csv`, `Baseline.bin` / `Baseline.json` (when calibrated), `TopoMap.png`, `TopoMapGrid.png`, `TopoMap.csv`, `TopoGrid.bin`, `TopoStats.csv`, `TopoStats.json`, `TopoProfiles.json`, `AcrossProfile.csv`, `AlongProfile.csv`, `ScanLineProfiles.csv` (single-frame maps), `TopoReplay_<time>s.png` (saved replay images) |
| **Laser line scan (flake topography)** | AVFoundation main camera at up to 240 fps + your line laser (laser-line triangulation) | `Profiles.bin` (raw sub-pixel line position per column and frame), `LaserFrames.csv`, `LaserRecording.json` (settings and calibration), and the same map files as Line scan (`TopoMap.png`, `TopoMap.csv`, `TopoGrid.bin`, `TopoStats.csv`, …) |

Room, equipment and object scans can be:
- opened in the built-in 3D viewer (orbit, zoom, pan, tap two points to measure on the model),
- opened in **AR Quick Look** to place the model at 1:1 scale and walk around it,
- shared (AirDrop, Mail, OneDrive, Google Drive) or pulled from the Files app: *On My iPhone › Phone LiDAR › Scans*.

Line scans open to **Topographic map + variance statistics**, **Topographic replay (real time, adjustable speed)** and **Play back recording (with speed)**; all their files are shareable the same way.

Home lists **Saved scans** and, when there are any, **Incomplete scans** (see *Library, deleting and recovering*).

## Folder layout

```
project.yml                     XcodeGen spec (the .xcodeproj is generated on the build Mac)
Support/Info.plist              App settings (camera and Photos-save permissions, Files-app access)
PhoneLidar/App/                 App entry + home screen, camera-permission screen, keep-screen-awake helper
PhoneLidar/Room/                RoomPlan scanning + CSV report
PhoneLidar/Mesh/                LiDAR mesh scanning, AR measuring, OBJ/PLY/USDZ export
PhoneLidar/Object/              Object Capture + photogrammetry
PhoneLidar/Line/                Line scan: LiDAR + video capture, speed tracking, recording and recovery of
                                interrupted recordings, playback, topographic map builder and statistics,
                                real-time topographic replay (TopoReplay*.swift, TopoGridFile.swift)
PhoneLidar/Laser/               Laser line scan: wide-camera capture, line detection, calibration, LiDAR height probe,
                                Profiles.bin recording, laser map builder
PhoneLidar/Viewer/              SceneKit 3D viewer with measuring
PhoneLidar/Library/             Scan detail / share / rename / delete, incomplete scans
PhoneLidar/Storage/             Scan storage, unit formatting, CSV
PhoneLidar/Assets.xcassets/     App icon
Tests/PhoneLidarTests/          Unit tests (run in the cloud build)
docs/                           Requirements, design, implementation plan, review records
CLAUDE.md                       Rules for the coding agents
.github/workflows/ios-build.yml Cloud build and tests (unsigned .ipa, optional TestFlight upload)
```

---

## Step 1 — Put the code on GitHub (one time, done)

1. Sign in at github.com → **New repository** → name it `PhoneLidar` → Private or Public → **Create repository**.
   - Public repos get unlimited free macOS build minutes. Private repos get 2,000 included minutes a month, and macOS minutes count 10×, so about 200 real minutes (roughly 20 builds).
2. On the new repo page click **uploading an existing file**.
3. In Windows Explorer open the unzipped `PhoneLidar` folder, select **everything inside it** (including the `.github` folder) and drag it onto the browser page. Click **Commit changes**.
   - Check that the repo shows the **folders** (`PhoneLidar/`, `Support/`, `.github/`) and not loose `.swift` files at the top level. Selecting individual files instead of folders flattens the upload, and the build then stops with *missing source directory PhoneLidar*.
   - Check that `.github/workflows/ios-build.yml` appears in the repo. If the browser skipped the `.github` folder, use **Add file › Create new file**, type `.github/workflows/ios-build.yml` as the name and paste the file's contents.
   - Alternative: install GitHub Desktop, clone the repo, copy the files in, commit and push.

## Step 2 — Build the app in the cloud

1. Open the repo's **Actions** tab. If asked, click **I understand my workflows, go ahead and enable them**.
2. Pick **Build iOS app** → **Run workflow** → **Run workflow**. Runs also start by themselves for every push to `main` that changes more than Markdown files, and for every pull request into `main`.
3. Wait for the green checks (about 2–10 minutes). A run has two jobs:
   - **unsigned-ipa** builds the app and packages the `.ipa`. The project must stay free of compiler warnings: any warning fails this job, and the run summary shows the warning count (**Compiler warnings: 0**).
   - **unit-tests** runs the unit tests on the newest iPhone simulator (no LiDAR needed; they cover file formats, statistics, speed tracking, baseline, replay data and formatting). The run summary shows **PASSED: N tests passed, 0 failed**, and also fails on warnings. Both jobs should be green before a pull request is merged.
4. Open the finished run, scroll to **Artifacts**, download `PhoneLidar-unsigned-ipa-N` (signed in to GitHub). It is a zip containing `PhoneLidar-unsigned-N.ipa`; unzip it. The `.ipa` is made even if the tests fail, so install only from a run where both jobs are green.

If a job fails, the run's summary page lists the compiler errors (**Build errors**) or the failed tests. Two more artifacts help:
- `build-log-N` (kept 14 days): the full logs of the app job, `xcodegen.log` and `xcodebuild.log`.
- `unit-test-results-N` (only when the tests fail, kept 14 days): the test `.xcresult` and the logs of the test job, including `unit-tests.log`.

The cloud build installs XcodeGen 2.46.0 from a release file whose checksum is verified first, and the workflow only has read access to the repository.

## Step 3A — Install for free with Sideloadly (free Apple ID, re-sign every 7 days)

1. On Windows install **iTunes** from apple.com/itunes/download/win64 and the non-Store **iCloud** installer (the Microsoft Store versions do not work with Sideloadly; uninstall them first, along with the Store apps *Apple Devices*, *Apple Music* and *Apple TV*, which stop iTunes from seeing the phone). Then install **Sideloadly** from sideloadly.io.
   - Check: `appwiz.cpl` lists iTunes, Apple Mobile Device Support and Bonjour. If iTunes still doesn't see the phone, install `usbaapl64.inf` from `%ProgramFiles%\Common Files\Apple\Mobile Device Support\Drivers` (right-click › Install) and restart *Apple Mobile Device Service* in `services.msc`.
2. Plug in the iPhone, unlock it and tap **Trust This Computer**.
3. Open Sideloadly, drag the `.ipa` onto it, enter your Apple ID, click **Start**, enter the password / 2FA code when prompted.
4. On the iPhone:
   - **Settings › General › VPN & Device Management** → under **DEVELOPER APP** tap your Apple ID → **Trust** (needs internet). Without this the app shows *Untrusted Developer*.
   - **Settings › Privacy & Security › Developer Mode** → On → restart → confirm.
5. Launch **Phone LiDAR** and allow camera access. If you turn camera access off later, the scan screens show **Camera is off** (Line scan: *Camera access is off for Phone LiDAR…*) with an **Open Settings** button.

Free Apple ID limits: the app stops opening after 7 days until it is re-signed (drag the same or a newer `.ipa` into Sideloadly with the same Apple ID; scans are kept). Sideloadly's automatic-refresh option does this over Wi-Fi while the PC is on. Free accounts are limited to 3 sideloaded apps and 10 new App IDs per 7 days.

## Step 3B — Install with TestFlight (paid Apple Developer Program, 99 USD/year)

TestFlight builds stay installable for 90 days, install over the air, and need no PC after setup.

One-time setup, all in a web browser:

1. Enroll at developer.apple.com/programs (or in the Apple Developer app on the iPhone).
2. **developer.apple.com › Certificates, IDs & Profiles › Identifiers › +** → App IDs → App → Bundle ID `ca.gervais.phonelidar` (if taken, choose another and change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to match).
3. **appstoreconnect.apple.com › Apps › + › New App** → iOS, name "Phone LiDAR" (any unique name), pick the bundle ID above, SKU `phonelidar`.
4. **App Store Connect › Users and Access › Integrations › App Store Connect API › Team Keys › +** → name `github`, access **App Manager** → **Generate**. Note the **Issuer ID** and **Key ID**, and download the `AuthKey_XXXX.p8` file (downloadable once).
5. Make a certificate private key on Windows. Open PowerShell and run:
   ```
   ssh-keygen -t rsa -b 2048 -m PEM -f cert_key
   ```
   Press Enter twice for an empty passphrase. This creates `cert_key` (private key) and `cert_key.pub` (not needed). Never commit these files (the repository ignores them).
6. In the GitHub repo: **Settings › Secrets and variables › Actions › New repository secret**, add four secrets:

   | Name | Value |
   |---|---|
   | `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from step 4 |
   | `APP_STORE_CONNECT_KEY_IDENTIFIER` | Key ID from step 4 |
   | `APP_STORE_CONNECT_PRIVATE_KEY` | Full text of `AuthKey_XXXX.p8` (open in Notepad, copy everything including the BEGIN/END lines) |
   | `CERTIFICATE_PRIVATE_KEY` | Full text of `cert_key` from step 5 |

Each release:

1. **Actions › Build iOS app › Run workflow**, tick **Also sign and upload to TestFlight**, run. The signing and upload job starts only after the unsigned build and the unit tests have passed.
2. After the run finishes, App Store Connect processes the build (5–30 minutes).
3. **App Store Connect › your app › TestFlight › Internal Testing › +** → create a group, add yourself. Install the **TestFlight** app on the iPhone and install Phone LiDAR from there.

The signing step uses Codemagic's open-source CLI tools (`codemagic-cli-tools` on PyPI) to create the distribution certificate and provisioning profile through the App Store Connect API, so no Mac Keychain is involved.

---

## Library, deleting and recovering

- **Delete** always asks first. On Home, swipe a scan left and tap **Delete** (a full swipe does not delete); a dialog "Delete this scan and all of its files?" shows the scan's name. On the scan screen, **Delete scan** shows the same dialog. If the folder cannot be removed, "Could not delete" suggests deleting it in the Files app.
- **Recovered recordings**: if the app was closed or killed while a Line scan was recording or saving, the app recovers that recording by itself (when Home loads, when the app comes back to the front and after a Line scan screen closes). A folder must have been untouched for 30 seconds first, so a recording that stopped moments ago is picked up shortly afterwards. The recovered scan appears under **Saved scans** named "Line <date> (recovered)", and a notice under **Line recordings** on Home explains it until you tap **OK**. Its summary says "Recovered: the app closed before this recording was saved. The last seconds and the end of the video may be missing." and "Map not built yet": open **Topographic map** and tap **Rebuild map**. If the recording stopped normally but could not be added to the library (for example storage was full at that moment), it is recovered with its own name and summary plus a "Recovered: the recording stopped normally, but the scan could not be added…" line. When a cut-off `Recording.json` had to be repaired, the scan keeps the note that the last frames may be missing, even after **Rebuild map**.
- **Incomplete scans** (only shown when there are some): folders that never got their `scan.json` (the app closed, crashed or ran out of space before the scan finished). Open one to see its size and files, **Share** each file (or **Share all files**), or delete it ("Delete these files?"). A folder from an interrupted Line recording is titled **Interrupted recording**; its **Recover recording** button recovers it now (do this before sharing, so `Recording.json` is repaired first; a folder touched in the last 30 seconds waits) and shows **Recovering…**, and "Last attempt failed: …" explains a failure. Its delete dialog ("Delete this interrupted recording?") reminds you that it can be recovered instead. While a recovery is running, **Delete** is not offered for an interrupted recording.
- **Rename** on the scan screen changes the name shown in the app (the folder keeps its name); if the new name cannot be saved, "Could not rename" explains why.
- A scan written by a newer version of the app, or with a damaged `scan.json` field, still opens: unreadable fields get neutral values, and a scan type this version does not know shows as type "Scan" and is left unchanged when you rename it.
- **Save Image** / **Save Video** in the share sheet save to Photos. iOS asks for permission the first time ("Phone LiDAR saves a scan image or video to your Photos only when you choose Save Image or Save Video in the share sheet."); the app only adds, it never reads your photos.

## Scanning tips

- **Room scan**: start facing a wall, move slowly around the perimeter, tilt up and down to catch doors, windows and furniture. Tap **Done scanning**, wait for the model, then **Save scan** (the button shows **Saving…** while the files are written). The screen stays awake while scanning. A scanning error appears in a red banner and Save can be tried again.
- **Equipment scan**: hold the phone 0.5–3 m from the surface (LiDAR range is about 5 m). Sweep until the coloured mesh overlay covers everything. To measure, aim the centre crosshair (it marks exactly the measured point) and tap **Set start point**, then **Set end point** (tapping the screen works too). Undo removes the last point or measurement. The eye button hides the mesh overlay. **Save** shows the stage and a progress bar while the OBJ, PLY and USDZ files are written in the background; if the save fails the scan session keeps running so you can try again. A phone call or another app pauses scanning ("Scanning paused (camera in use or app in background).") and it resumes by itself. The screen stays awake while scanning.
- **Object capture**: works best on objects from about 10 cm up to a few metres with texture and even lighting. Tap **Detect object**, fit the box, **Start capture**, walk three loops (low, middle, high), **Finish**. Reconstruction runs on the phone and takes several minutes; the screen stays awake, and you should keep the app open ("Your photos are already saved."). On iOS 18+ **Area mode** skips the box for things too large or irregular for one. **Cancel** during capture asks "Discard this capture?" once photos have been taken.
  - **The photos are never deleted when the model cannot be built** (error, **Stop**, or the app closed): the scan stays in the library with its photos and the summary "Reconstruction failed: …". Tap **Retry reconstruction** on the failure screen, or later on the scan screen (**3D model › Retry reconstruction**), and use **Share photos** in the scan's Files section to get the photos out.
  - If the model was built but the scan record could not be written, the screen says "3D model built, but not saved to the library" and **Try saving again** only rewrites the record; the finished `Model.usdz` and the photos are kept. **Close** on that screen tries the save once more. If it still fails, the scan screen offers **Add the finished model** ("The model was built but not added to this scan. Nothing is rebuilt.") instead of **Retry reconstruction**; a finished model is never rebuilt or deleted.
  - If even the first scan record could not be written, the failure screen says the photos are kept in the scan folder but the scan could not be added to the library, and gives the Files-app path (*Phone LiDAR › Scans › <folder>*).

## Line scan (moving material)

**Mounting**
- Phone in **portrait**, camera pointing straight down, rigid vibration-isolated mount, on USB-C power.
- Material moves **right → left on the screen** (the direction picker switches to left → right).
- Height: about 1–1.5 m for best accuracy (≈1.27 m of width per metre of height across the long edge of the screen). A 12 ft (3.66 m) width needs ≈2.9 m from one phone.
- Line the phone up with the travel: the **angle** readout should be near 0°.
- Level it with the **bubble level** on the recording screen (bubble centred and green = within 0.5°).
- With the phone in its final position and the surface empty, tap **Calibrate baseline** (keep everything still for ~3 s). Recalibrate whenever the phone is moved.
- **The screen stays awake for as long as the Line scan screen is open** (mounting, levelling, calibration and recording), so an auto-lock cannot cancel a calibration.
- If camera access is off, the screen says "Camera access is off for Phone LiDAR. Turn it on in Settings › Privacy & Security › Camera, then reopen Line scan." and offers **Open Settings**.

**Recording screen**
- Live speed in mm/s, m/min and ft/min (half-second average), texture **lock %**, distance to the surface, travel angle and a speed sparkline.
- **Fastest** (mm/s): fastest of 24 speed zones (6 across × 4 along the travel, each scaled by its own LiDAR distance), marked on the picture with an orange box. **Tap the picture** to place a crosshair and read **At point** speed (mm/s) for the zone under it; ✕ clears it.
- Depth overlay: dark blue = farthest, dark red = closest; the legend shows the current range. The slider sets overlay strength.
- Before recording: **Raw LiDAR depth (unfiltered)** (default off = Apple's filtered depth), **Short shutter (1/1000 s) for sharp texture** (default on), **Direction**, **Map: averaged / single frame**. These are locked while a baseline is being calibrated, so a baseline always uses one depth setting.
  - **Map: single frame** builds the map from one LiDAR reading per cell, with no averaging between frames, and switches **Raw LiDAR depth** on (Apple's filter smooths over time, which smears moving material). Each cell takes the reading from the frame in which that spot passed closest to the centre row of the LiDAR view. A single-frame map shows the LiDAR's real per-reading noise and its laser-spot spacing (≈ 5 cm at 1 m); it does not resolve individual strands. For strand-level heights use the **Laser line scan**.
  - The short shutter is an **auto-exposure limit**: the camera keeps adapting to the light but never exposes longer than 1/1000 s, and raises ISO instead. Add light if the picture is dark or noisy. Switching it off returns to the camera's normal exposure limit.
- **Bubble level** (camera-down mount): the bubble moves toward the high edge; green ≤ 0.5°, yellow ≤ 2°, red above; rim = 3°. The two rings mark **0.5° and 2°** at the same scale the bubble moves, so the bubble's centre sits on a ring at exactly that tilt. Readout ↔ = left/right edge, ↕ = top/bottom edge, + = right/top edge high, from the gravity sensor. **Zero here** saves the current orientation as level (lay the phone flat on the floor or conveyor first, tap Zero here, then mount it); **Reset** returns to gravity. The orange ring / *Phone vs surface (LiDAR)* readout is the tilt relative to the surface below, from a plane fitted to the depth map.
- **Baseline calibration** (flat-surface zero): with the surface below empty, tap **Calibrate baseline on the empty flat surface**. About 90 frames (~3 s): the per-pixel trimmed mean of the first 60 becomes the baseline, the last 30 check it. This removes phone tilt and the LiDAR's fixed pattern across its field of view, which otherwise make a flat surface read different distances in different areas. The screen shows the distance to the surface, the flat-surface spread before (σ and P1–P99 range) and after correction (σ), and the **coverage**: the share of the view that had steady LiDAR readings (the rest is filled from a plane fitted to the rest).
  - **Coverage below 80 %** shows a yellow warning ("Only N % of the view had steady LiDAR readings; the rest is estimated from a fitted plane. Clear the view and recalibrate for best accuracy.") and a short "Baseline coverage only N %" warning stays on screen while recording.
  - **Coverage below 50 %** is refused ("Calibration refused: only N % of the view had steady LiDAR readings (at least 50 % needed)…"): make sure the whole picture shows the empty flat surface, 0.3–4 m away, with nothing moving, then try again.
  - A calibration is cancelled if the camera is interrupted, the app goes to the background or the screen closes ("Calibration cancelled: … Tap Calibrate again when the phone is steady.").
  - From then on the overlay, legend (Low → High), centre height and **σ** flatness readout are **height above the surface** (dark blue = lowest, dark red = highest). Warnings appear if the phone's tilt changes > 0.3° or the depth filter setting differs from the calibration; they stay visible (in short form) while recording. **Recalibrate** / **Clear**. Stored in *Files › On My iPhone › Phone LiDAR › Calibration* and copied into every recording whose depth map has the same size; if the copy fails, the scan summary says so and the map shows distances from the camera.
- Red button starts/stops. After stopping the app saves the recording ("Saving recording…"), builds the map ("Building topographic map…", a few seconds), then opens the scan. **Close** is disabled while recording, saving or building.

**What is saved automatically, and what stops a recording**

Recording needs the camera, which iOS stops when the app leaves the screen. The app therefore stops and saves the recording, finishing it in a background task, in each of these cases, and the scan summary then says "Recording stopped early: <reason>.":
- the app goes to the background (screen locked or another app opened),
- the camera is interrupted (for example a phone call or another app using the camera; a banner "Camera paused: …" shows) or stops with an error (the app restarts the camera up to 3 times in a row; the banner "Camera error: …" says whether it is restarting),
- the phone is too hot: at **serious** heat the banner "Phone is hot: live overlay slowed to reduce load. Shade the phone or improve airflow." appears with a **Hot** label and the live overlay refreshes less often, but recording continues; at **critical** heat the banner says "Phone too hot: recording is stopped and cannot start until the phone cools down." and the recording is saved,
- free storage falls below 300 MB ("iPhone storage is almost full (… left)"); recording does not start with less than 1.0 GB free ("Not enough free storage to record: … Delete old scans or free up space on the iPhone."),
- a write fails ("the recording could not be written to storage (…)"); the first write error stops the recording and the frames already written are kept.

After Stop, if the scan's summary cannot be saved once the map step has finished, a notice under **Line recordings** on Home says so ("…: the map was built, but the scan summary was not updated…" or "…: the map was not built and the scan summary was not updated…"); open the scan and tap **Rebuild map**. A recording that has frames is never deleted when something goes wrong: the scan is added to the library straight away ("Map not built yet: open Topographic map and tap Rebuild map." until the map is built). If no frames were recorded the folder is removed and the screen says "Recording not saved: no frames were recorded". "Recording not started: …" explains a refused start (hot phone, no frames from the camera within 3 s, folder or file creation failed). If the video encoder has a problem the depth, speed and map data are still complete: the summary says "Video incomplete: …" or "Video: N of M frames skipped by the busy encoder …", and a "Video not recording: …" warning shows while recording.

If the app is killed anyway (iOS closes it, the battery dies), the files already written stay on disk and the recording is recovered the next time the library loads (see *Library, deleting and recovering*). The recording is written to disk as it goes, so memory use does not grow with its length; `Video.mov` is written in 5-second fragments, so it plays up to the last complete fragment, and a recovered recording can therefore have a video that is shorter than its depth frames.

**How speed is measured**: each video frame is matched against the previous one to find how far the surface texture moved; the LiDAR distance of the tracked area converts pixels to millimetres. The main speed uses a large central area; zone speeds repeat this for each of the 24 zones (128 × 128-pixel templates, up to 320 pixels per frame; zones near the downstream edge match backwards so they have room to search). Speed shows "no texture lock" on blank, featureless surfaces. When you change the direction, the old speed readings and the travel estimate state are cleared, so they cannot carry into the new direction. At Record a speed measured in the last 2 seconds is kept, so a short blank stretch at the start of a recording still moves the map on at that speed; an older speed is cleared, and the recording then has zero travel until its first real speed reading. A recording in which no frame got a speed reading says so in its summary: "Speed: no texture lock (map uses zero travel)", or, when a speed from just before Record moved the map, "map travel N mm comes from the speed held from before Record" (a speed at most 2 seconds old; in recordings made before this version, a held speed of any age). The frames and seconds in the summary are counted from `Recording.json` as saved.

**Playback**: Camera / Blend / Depth views, scrubbing, 0.1×–2× rate, per-frame speed, distance, travel and lock %, and a speed-versus-time graph with the playback cursor.
- **Without a video, or when the video fails**, playback still works: "No Video.mov in this recording: playing the depth frames only." (or "Video.mov could not be played (…): playing the depth frames only.") and only the **Depth** view is offered; playback runs on the recorded frame times.
- **With a short video** (a recovered recording, whose video can end before the depth frames) playback continues on the frame times after the video ends: the Camera and Blend views then rest on the last picture while the depth keeps playing.
- Speed and frame details sit above the picture and the probe readout below it, so the whole picture can be touched. **Fastest on screen** (mm/s) is shown under the main speed, with the orange marker on the picture.
- The probe panel's **Speed here** column gives the speed (mm/s, ±7-frame average) of the zone under the probe, with the fastest speed beneath it.
- **Touch probe** (playing or paused): touch or drag anywhere on the picture to place a crosshair (touches in the black bars snap to the nearest edge). **Current** = distance at that point in the frame on screen (3×3-pixel median, updates every frame); with a baseline it is height above the surface. **Min (closest)** and **Max (farthest)** (with a baseline: **Min (lowest)** / **Max (highest)**) = extremes at that point over the whole recording, with their times; tap either to jump there. Also mean, std dev, range, frames with data, a distance-vs-time trace and the point's position in mm from the picture centre. ✕ removes the probe.
- A `Recording.json` that was cut off is repaired when the recording is opened.

**Topographic map + statistics**
- Depth frames are placed using the measured travel and every reading that lands in the same cell is averaged.
- **Cell size**: at least the size of the largest depth pixel on the surface (the distance of the farthest readings that land on the map, the edge of the picture and the phone's tilt to the surface all count), rounded **up** to a whole mm; ~4 mm at 1 m for a level phone before rounding up. This guarantees neighbouring depth pixels never skip a cell, so there are no empty stripes in the map and a stationary or slow recording still fills its cells. The size used is shown in the summary and in `TopoStats.csv` (`cell_size`). Very long recordings use a larger cell so the map stays under 3,000,000 cells.
- **Measured area**: the map, **coverage**, **length** and **width** describe the observed material only. The empty margin around the data (padding that is added while stitching to leave room for relief) is trimmed off. Coverage = cells with data ÷ all cells of the trimmed map; length and width = the trimmed map's columns and rows × cell size. A gap-free scan therefore reads close to 100 % coverage.
- The map is oriented as seen on screen during recording (leading edge on the left for right → left travel). Pinch to zoom.
- Statistics: distance mean, variance, std dev, CV, min/max/range, P1/P5/median/P95/P99; across-width profile and along-travel profile std dev and range; local residual std dev; repeat-reading noise; readings per cell; coverage; speed mean/std dev/min/max and % of frames with texture lock. Profile charts plot distance with "up = closer to the camera".
- With a baseline saved in the recording, every value is **height above the flat surface** (map, statistics prefixed `height_` in TopoStats.csv, profiles, TopoMap.png legend Low → High); without one, values are distances from the camera. **The CV is only defined for distances**: in height mode the mean is near zero, so the CV row is hidden on screen, `height_cv` is blank in `TopoStats.csv` and `cvPercent` is absent from `TopoStats.json`.
- **Rebuild map** reprocesses the saved recording (repairing a cut-off `Recording.json` first and noting it in the summary), keeps the old map on screen while it works, shows "Map not rebuilt: …" if it fails, and updates the scan's summary and file list when it is done ("Map rebuilt, but the scan summary was not updated: …" if that last step fails). All map files are written under temporary names and renamed together at the end, so a failed rebuild never leaves new statistics next to an old picture.
- **Map method** (above **Rebuild map**): *Averaged* (the mean of every reading in a cell) or *Single reading* (one reading per cell, nothing averaged). Pick one and tap **Rebuild map**; the replay then uses that map. A single-reading LiDAR map also writes `ScanLineProfiles.csv` (one row per frame: the reading on the centre row of the view at each across position; an averaged rebuild removes it) and skips depth frames that only repeat the previous frame (the summary says how many). For single-reading maps the repeat-reading noise is shown as "—" and readings per cell is 1.

## Topographic replay (real time)

Scan › **Topographic replay (real time, adjustable speed)**. The screen turns to landscape (turn the phone to portrait for a stacked layout) and goes back to portrait when you leave. It starts playing at 1×.

**What it shows**: the topographic map building up line by line in recording time, as a scrolling 3D strip laid out like the X-ray mat-density replay.
- The newest line is at the right edge (black marker); older material scrolls left. The window is 2 × the strip width by default.
- The newest line is the material leaving the downstream edge of the LiDAR's view. At that point every reading of that line has been averaged, so at each moment the replay shows only data that existed at that moment. Only complete display blocks are drawn: the newest drawn block can sit up to one block to the left of the marker.
- **Run-out**: after the last frame the rest of the recorded material runs out at the last measured speed ("run-out after the last frame" in the header), so the whole map is always revealed by the end. If that speed is so slow that the run-out would take longer than 60 s, it runs faster and ends after 60 s; if no speed was measured, the rest runs out over 3 s.
- Values are heights above the baseline when the recording has one. Without one they are relative heights: median distance − distance (+ = closer to the camera).
- **Header**: title; replay time t of total, frame N of M, speed (mm/s and m/min); newest-line average and its difference from target, on-screen average, std dev, min / max, % within ± tolerance. These figures, the along chart, the across-width profile and the statistics on the saved image use the **measured blocks only**; blocks that are only filled in for the picture are not counted.
- **3D strip**: surface coloured by height; front and end walls coloured like the edge above them (vertical stripes); height axis (mm) at the back-left; across axis (mm from the image centre line) along the newest end. The pink (upper) and light-blue (lower) **tolerance planes** show where there is no data yet. Short gaps between measured blocks are bridged for the surface (up to 3 blocks across, up to 8 along the travel); nothing is extended past the measured data, so empty edges stay empty.
- **Under the strip**: mean height of each line in the window (green), the tolerance band, and the replay time at which each line was completed.
- **Colour bar**: target − 2 tolerances (blue) → target (green) → target + 2 tolerances (red), labelled at every tolerance step.
- **Right panel** (below the colour bar in portrait): across-width profile of the newest line (red) and the last second's average (grey dashed), with the target and tolerance lines. Top of the panel = top of the recording screen.

**Controls**
- Restart, step back / forward one recorded frame (1/30 s steps in the run-out), play / pause, time slider.
- **Speed** menu: 0.1×, 0.25×, 0.5×, 1× (real time), 2×, 4×, 8×, 16×. The settings sheet has a 0.1×–20× slider.
- **3D / Map**: Map is the same data seen from straight above, with the newest line at the right.
- On the strip: drag up / down = view angle, drag left / right = side angle, pinch = zoom, double-tap = reset view.
- **Settings** (slider icon): speed; **target** and **± tolerance** (default = recording median and robust std dev, rounded; Reset button); window length (1–10 × strip width); height scale; smooth surface (3 × 3); tolerance planes on / off; view angle, side angle, zoom.
- **Save image** (download icon): PNG of the strip with title, statistics and colour bar, saved as `TopoReplay_<time>s.png` in the scan folder ("Could not save image" with the reason if it fails; "Could not update the scan" if the new file cannot be added to the scan's file list), then the share sheet opens. The file name, the picture and the header all show the same time.

**Notes**
- The map grid is averaged into square blocks for display (at most about 260 blocks along the window and 90 across; the last block row can be narrower) so the strip can be redrawn at every screen refresh. When the block size changes (for example while you drag the window-length slider) the new blocks are built in the background and the current picture stays until they are ready.
- Recordings made before the replay existed have no `TopoGrid.bin`; the first time the replay opens it builds the map (a few seconds). **Rebuild map** on the Topographic map screen also writes it.
- Leaving the screen while it is still loading does not start a replay in the background.

**Expected performance** (from published LiDAR measurements; untested on this app yet): ~15 real LiDAR samples per second (30 depth frames/s delivered), ±1–2 mm height after averaging at ~1 m, real laser-spot spacing ≈ 5 cm across at 1 m; speed ≈ ±0.2–0.3% once the distance scale is checked against a known speed or length.

## Laser line scan (flake topography)

A line laser draws a thin line across the belt at an angle; the phone's main camera looks straight down and finds the line in every frame. Where the surface is higher, the line moves along the picture. The shift gives the height of each point on the line, frame by frame, with no averaging. This resolves single strands, which the LiDAR cannot.

**What you need**
- A line laser (Class 2 or lower where people can look into it; follow plant rules). Red (650 nm) or green (520–532 nm). A thin, bright line works best.
- Optional but recommended: an optical band-pass filter for the laser's colour in front of the phone camera (blocks plant lighting).
- A rigid mount that holds the phone and the laser in fixed positions relative to each other.
- A shim or gauge block of known thickness (for example 10.0 mm, measured with a calliper).

**Mounting**
- Phone in **portrait**, camera pointing straight down (level it with a bubble level), on USB-C power.
- Laser line **across** the belt, from the left or right side of the screen at about 30–45° from vertical. A larger angle gives more height resolution and more shadowing behind tall strands.
- Put the line near one side of the picture (not the middle): the speed is measured from the rest of the picture.
- Height: 0.5 m gives 0.33 mm per camera pixel and 0.64 m of width; 1 m gives 0.66 mm per pixel and 1.27 m of width. The line is read on every 2nd pixel column, so a profile point every 0.66 mm across at 0.5 m and every 1.3 mm at 1 m; the smallest map cell is that spacing rounded up to 0.1 mm (0.7 mm and 1.4 mm).

**Calibration (once per mount; the app keeps it)**
1. **Camera height**: lens to belt in mm. Type it and tap **Set**, or tap **LiDAR** to measure it (check against a tape measure). Recording is not offered while a typed height has not been set.
2. **Calibrate baseline** with the belt empty and the laser on: 60 frames over about 1 s; focus and white balance are locked. The line must be found on at least half of the width.
3. **Measure shim**: put the shim on the belt under part of the line (at least a tenth of the width), type its thickness, tap **Measure shim**, then remove it. This sets the height scale. If you cannot use a shim, type the laser angle from vertical, pick its side and tap **Use** (less accurate: the angle is hard to measure exactly). Either way the app corrects each column for the line's distance from the picture centre. With **Use**, the camera tilt along the travel (read from the phone, see the level zero below) is taken into account.
- Recalibrate after moving the phone, the laser or the focus. A calibration made with another camera format (picture size, crop or binning, which can differ between frame rates) is not used; the screen says so.

**Side-wall calibration (when the belt cannot be cleared)**
- Pick **Side walls** under Calibration. The laser line must cross both side-wall tops, and both must be in the picture: the width seen at wall-top height is 1.27 × (camera height − wall height), so a 12 ft line with 300 mm walls needs the camera at about 3.3 m. Make the wall tops matte where the line crosses them (paint or tape).
- Enter: **camera height** (lens to belt; Set or LiDAR), **wall top above belt** (mm, measured to ±1 mm), **laser angle** from vertical measured with a digital angle gauge on the laser (±0.1°) and its side. Lay the phone flat (screen up) on a surface checked with a spirit level and tap **Zero here** once; the camera tilt is then read from the phone (this zero is separate from Line scan's conveyor zero). The camera must be level across the belt within 0.5° (the screen warns otherwise); a tilt along the travel is allowed and corrected.
- Tap **Calibrate on the side walls** (about 1 s, focus locked). The wall tops are drawn in orange; the app assumes a flat belt and draws the belt line straight between the walls.
- **Wall re-zero every frame** (on by default): the walls are measured in every frame and the belt line follows them, which removes drift and mount vibration. The map and the height readouts leave out the walls.
- Accuracy (worst case over 0–200 mm mat height): laser angle ±0.1°, camera height ±5 mm, wall height ±1 mm → within 2.5 mm; ±0.2° / ±10 mm / ±2 mm → within 5 mm; a ±1° angle gives up to 12 mm. An error in the camera tilt reading (for example a zero made on a surface that is not level) adds like an error in the laser angle. The wall height error passes straight into every height.
- A new camera height (Set or LiDAR) refits the wall calibration from the stored wall rows. After moving the phone or the laser, or after a new wall height or laser angle, calibrate on the side walls again; **Measure shim** and **Use** are not offered on a side-wall calibration.

**Recording screen**
- Green dots = the line found in each frame; yellow = the calibrated baseline.
- Speed, % of the line found, median and maximum height on the line, picture size, actual fps and dropped frames, and a live across-width height profile.
- Speed is measured about 60 times a second from the part of the picture on the far side of the laser band; it needs at least 216 pixel rows there. If the band takes too much of the picture, the screen says "No room for speed tracking": move the line toward an edge or lower **Max height**.
- Settings: **frame rate** 240 / 120 / 60 fps (if a rate is not available the highest available is used and the screen says so), **shutter** limit 1/1000–1/4000 s, **exposure** bias (lower it until only the line is bright), **max height above belt** (sets the search band), **direction**, **map** single reading (default) or averaged.
- Profile spacing along the belt = speed ÷ frame rate:

| Speed | 240 fps | 120 fps | 60 fps |
|---|---|---|---|
| 100 mm/s | 0.4 mm | 0.8 mm | 1.7 mm |
| 500 mm/s | 2.1 mm | 4.2 mm | 8.3 mm |
| 1000 mm/s | 4.2 mm | 8.3 mm | 16.7 mm |

**Saved files and map**
- `scan.json` is written when recording starts, so a recording cut short by a crash stays in the library; open its map and tap **Rebuild map**.
- Recording stops and saves when the app goes to the background, the camera is interrupted, the phone is critically hot, storage falls below 300 MB or a write fails. It does not start with less than 1 GB free.
- After Stop the map is built: heights above the belt, one laser reading per cell (the one nearest the cell centre) or averaged. Cell = the larger of the across column spacing and the travel per frame. Very long runs at fine cells are coarsened so the map stays under 3,000,000 cells; `Profiles.bin` always keeps every reading.
- The scan opens to **Topographic map + variance statistics** (with the map-method picker and Rebuild map) and **Topographic replay**.

**Expected performance** (untested on the device yet): height per single reading ≈ 0.05–0.15 mm at 0.5 m and 0.1–0.3 mm at 1 m once shim-calibrated (laser speckle on wood limits it); strand edges facing away from the laser can be shadowed (no reading there).

## Opening scans on Windows

- `.obj` / `.ply`: Blender, MeshLab, CloudCompare, Autodesk tools.
- `.usdz`: Blender (File › Import › Universal Scene Description), NVIDIA Omniverse.
- `.csv`: Excel. `TopoMap.csv`: rows = across the material (top → bottom of the screen, mm from the image centre line), columns = along the travel (mm from the left edge of the map), values = height above the baseline in mm when the recording has one, otherwise distance from the camera in mm (blank = no data). The map is trimmed to the measured area, so the first column and the first row are the first with data.
- `RoomReport.csv`: the element table (header `type,category,number,width_m,…,confidence`, one row per wall, door, window, opening, floor and object) is followed by an empty line and a **totals block** with its own header `summary_item,value,unit`: `wall_count` (count), `total_wall_length` (m and ft_in), `wall_height_max` (m and ft_in; left out when there are no walls), `floor_area` (m2 and ft2). Excel shows both tables on one sheet; filter on the first column to use the element table alone.
- `TopoStats.csv`: `metric,value,unit` rows. In height mode `height_cv` is blank. `map_length`, `map_width`, `coverage` and the profile files describe the measured (trimmed) area. `TopoStats.json` is the same data (`cvPercent` is absent in height mode).
- `TopoGrid.bin`: the stitched grid used by the replay. Header (little endian): `PLTG`, version (UInt32, must be 1), columns, rows (UInt32), cell size, qMin, xMin (Float64, mm), height mode (UInt32, 1 = heights above the baseline, 0 = distances from the camera), reserved (UInt32); then rows × columns Float32 values in mm, row-major (rows = across the material top → bottom of the screen, columns = along the travel left → right), NaN = no data. Same cells as `TopoMap.csv` (the trimmed map; the file is refused if it has more than 3,000,000 cells).
- `TopoReplay_<time>s.png`: saved replay images (time = replay time in seconds).
- `Baseline.bin`: width × height Float32 distances (mm) of the empty flat surface per depth pixel; `Baseline.json` holds its size, date, distance, spread before/after correction, coverage and tilt at calibration.
- `Frames.csv` and `ZoneSpeeds.csv`: written line by line while recording. `ZoneSpeeds.csv`: one row per frame, one column per zone (`zone{n}_across{c}_along{r}_mm_s`; across 0 = top of the screen, along 0 = right edge), mm/s, + = travel direction. After a recording that was cut off by a crash, up to about the last 64 kB of these files (and of `Recording.json`) may be missing, so they can end earlier than `Depth.bin` and their last line can be incomplete; the app only uses `Recording.json` and `Depth.bin`.
- `.mov`: any video player (HEVC). It is written in 5-second movie fragments, so a video cut off by a crash plays up to its last complete fragment.
- `Depth.bin`: header `PLDP`, version, width, height (UInt32 LE), then per frame a UInt32 byte count + LZFSE-compressed UInt16 distances in 0.1 mm (0 = no data, also 0 for 6.5 m and farther). A cut-off last frame is ignored; a header with a width or height above 8192 is refused. Frame times, speeds and depth intrinsics are in `Recording.json`.
- `Recording.json`: plain JSON, one object per frame. It is written while recording, so it is compact (not pretty-printed, keys not sorted): the first line holds the settings (`depthWidth`, `depthHeight`, `videoWidth`, `videoHeight`, `filteredDepth`, `shortShutter`, `direction`, `tileColumns`, `tileRows`) followed by `"frames":[`, then one frame per line, and `]}` at the end. Any JSON parser (Python `json`) reads it; recordings from earlier versions are pretty-printed with the same keys. A cut-off file is repaired by the app (complete frame lines kept, `]}` added).
- `ScanLineProfiles.csv` (single-reading LiDAR maps): `frame,time_s,travel_mm,repeated`, then one column per map row (across position in mm). Each row is one frame's reading on the centre row of the LiDAR view at each across position (height or distance, mm; blank = none); `repeated` = 1 for a depth frame identical to the previous one (not used in the map).
- `LaserRecording.json`: laser scan settings (picture size, requested and active frame rate, columns, camera intrinsics, shutter, exposure, max height, map method), the calibration (camera height, height scale and how it was set, baseline row per column, lens position) and, after Stop, frame count, duration and dropped frames.
- `Profiles.bin`: header (little endian) `PLLP`, version (UInt32 = 1), columns N, first column, column step, row scale (32), two reserved UInt32; then one 24 + 2·N-byte record per frame: time (Float64, s), travel (Float64, mm), speed (Float32, mm/s, NaN = none), flags (UInt32: 1 = tracked frame, 2 = speed valid), and N UInt16 line rows in 1/32 pixel (65535 = line not found). Height h = H·d / (A + d) with d = row − baseline row and H, A from `LaserRecording.json`. A cut-off last record is ignored.
- `LaserFrames.csv`: `frame,time_s,speed_mm_s,travel_mm,detected_pct,median_height_mm,max_height_mm`.
- `scan.json`: scan metadata (name, date, summary, file list); keys unchanged.
- `.recording-in-progress` (hidden, empty): marks a Line recording that has not been saved yet. It is removed once the recording has been saved and `Recording.json` reads back; you only find it in the folder of an interrupted recording. Hidden `.<name>.partial` files exist only while a map is being written (and can be deleted if the app was killed then).
- Object-capture photos (`Images/`) can be shared from the scan screen (**Share photos**) and reprocessed on a PC with photogrammetry software such as RealityCapture or Meshroom for higher detail.

## Changing the app

Edit the Swift files (in the GitHub web editor or locally) on a branch and open a pull request into `main`. The build and the unit tests run for the pull request; merge when both are green and the warning count is 0. Every merge to `main` that changes more than Markdown files builds a new `.ipa`. Install it over the old one with Sideloadly (same Apple ID) to keep existing scans.

## Developer documentation

- [`CLAUDE.md`](CLAUDE.md) — rules and conventions for the coding agents (constraints, build and test commands, workflow, model matrix, coding conventions).
- [`docs/requirements.md`](docs/requirements.md) — functional and non-functional requirements with traceability and status.
- [`docs/design.md`](docs/design.md) — architecture, algorithms, concurrency, byte-exact file formats, technology choices, risks.
- [`docs/implementation-plan.md`](docs/implementation-plan.md) — process, phased checklists, backlog and change log.
- [`docs/reviews/`](docs/reviews/) — milestone review records (every finding, its severity and its fix).
