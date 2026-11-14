# Phone LiDAR — iPhone LiDAR scanner built without a Mac

You need a Windows PC, a LiDAR iPhone (12 Pro / Pro Max or a newer **Pro** model, iOS 17+), a USB cable and a free GitHub account. The app is compiled on Apple hardware rented by GitHub Actions (`macos-26` runner with Xcode 26).

**Status (Nov 13, 2026):** the code is at github.com/AliG1111/PhoneLidar (public). Build #107 (`PhoneLidar-unsigned-ipa-107`) removes the Laser line scan (it needs a line laser), adds **Map: camera parallax** to Line scan (strand-level heights from the phone's own video, scaled by the LiDAR) and two height references that need no empty belt: **Camera height** and **Side walls** (see *Height reference* and *Camera-parallax map*). Build #91 (`PhoneLidar-unsigned-ipa-91`) added **Direction: Auto** (the travel direction is detected from the moving material, with Right → Left / Left → Right as a manual override) and **unlimited rotation** of the Topographic replay's 3D strip (drag any way, twist to roll). Build #85 added the single-reading LiDAR map; build #83 the **Remote link** (a second phone controls a Line scan phone). Earlier: build #61 added the M1 review fixes, unit tests in CI and the developer docs; build #23 the **Line scan** mode with baseline calibration, bubble level, local speeds, playback touch probe and the **Topographic replay** (real-time scrolling 3D strip, 0.1×–20×). Step 1 is done. Start at Step 2 or Step 3.

## What the app does

| Mode | Apple framework | Output files |
|---|---|---|
| **Room scan** | RoomPlan | `Room.usdz` (walls/doors/windows/furniture as boxes), `RoomMesh.usdz`, `CapturedRoom.json`, `RoomReport.csv` (every wall, door, window, opening, floor and object with W × H × D in m and ft-in, plus a totals block: wall count, total wall length, maximum wall height, floor area) |
| **Equipment scan (LiDAR mesh)** | ARKit scene reconstruction | `Mesh.usdz`, `Mesh.obj`, `Mesh.ply` (world-space, metres, Y up), `Measurements.csv` from live point-to-point measuring |
| **Object capture** | RealityKit Object Capture + on-device photogrammetry | `Model.usdz` (photo-textured, real scale), `Images/` folder with the source photos (kept even when the model cannot be built) |
| **Line scan (moving material)** | AVFoundation LiDAR depth camera + synchronized video | `Video.mov`, `Depth.bin`, `Recording.json`, `Frames.csv` (per-frame speed, fastest zone, travel, distance, tilt), `ZoneSpeeds.csv`, `Baseline.bin` / `Baseline.json` (when calibrated), `TopoMap.png`, `TopoMapGrid.png`, `TopoMap.csv`, `TopoGrid.bin`, `TopoStats.csv`, `TopoStats.json`, `TopoProfiles.json`, `AcrossProfile.csv`, `AlongProfile.csv`, `ScanLineProfiles.csv` (single-frame maps), `TopoReplay_<time>s.png` (saved replay images), `HeightReference.json` (camera-height or side-wall reference) |

Room, equipment and object scans can be:
- opened in the built-in 3D viewer (orbit, zoom, pan, tap two points to measure on the model),
- opened in **AR Quick Look** to place the model at 1:1 scale and walk around it,
- shared (AirDrop, Mail, OneDrive, Google Drive) or pulled from the Files app: *On My iPhone › Phone LiDAR › Scans*.

Line scans open to **Topographic map + variance statistics**, **Topographic replay (real time, adjustable speed)** and **Play back recording (with speed)**; all their files are shareable the same way.

Home lists **Saved scans** and, when there are any, **Incomplete scans** (see *Library, deleting and recovering*).

**Remote link** (Line scan only): a second iPhone with the app can start and stop a mounted Line scan phone, show its readouts and copy its scans for review, over a direct phone-to-phone Wi-Fi link (see *Remote control from a second phone*).

## Folder layout

```
project.yml                     XcodeGen spec (the .xcodeproj is generated on the build Mac)
Support/Info.plist              App settings (camera, Photos-save and Local Network permissions, Files-app access)
PhoneLidar/App/                 App entry + home screen, camera-permission screen, keep-screen-awake helper
PhoneLidar/Room/                RoomPlan scanning + CSV report
PhoneLidar/Mesh/                LiDAR mesh scanning, AR measuring, OBJ/PLY/USDZ export
PhoneLidar/Object/              Object Capture + photogrammetry
PhoneLidar/Line/                Line scan: LiDAR + video capture, speed tracking, recording and recovery of
                                interrupted recordings, playback, topographic map builder and statistics,
                                real-time topographic replay (TopoReplay*.swift, TopoGridFile.swift), height
                                references (HeightReference*.swift), camera-parallax map (Parallax*.swift)
PhoneLidar/Viewer/              SceneKit 3D viewer with measuring
PhoneLidar/Library/             Scan detail / share / rename / delete, incomplete scans
PhoneLidar/Storage/             Scan storage, unit formatting, CSV
PhoneLidar/Remote/              Phone-to-phone remote link: connection, pairing and encryption, status and
                                commands, scan copies, Remote screen and scanner settings
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
5. Launch **Phone LiDAR** and allow camera access. The first time the remote link is used, iOS also asks to find devices on the local network: tap **Allow** (needed on both phones). If you turn camera access off later, the scan screens show **Camera is off** (Line scan: *Camera access is off for Phone LiDAR…*) with an **Open Settings** button.

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
- Material can move **right → left or left → right on the screen**. With **Direction: Auto** (the default) the app works out which way from the moving texture; if it has trouble (blank or very uniform material), set **Right → Left** or **Left → Right** by hand.
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
- Before recording: **Raw LiDAR depth (unfiltered)** (default off = Apple's filtered depth), **Short shutter (1/1000 s) for sharp texture** (default on), **Direction** (Auto / Right → Left / Left → Right), **Map: Averaged / Single frame / Camera parallax**, and the **Height reference…** button (see *Height reference*). These are locked while a calibration is running, so a calibration always uses one depth setting.
  - **Direction: Auto** (default every time the screen opens): as soon as the material moves under the phone with visible texture, the app detects the direction (about half a second) and the line under the speed sparkline says **Material travel Right → Left (detected)**. Until then it says **Detecting the travel direction: needs moving material with visible texture**, the speed shows **— mm/s** and **Record is refused** ("Recording not started: the travel direction has not been detected yet…"; the remote phone gets the same answer). Once detected, the direction is kept while the line stops; if the material clearly runs the other way for about half a second, the detection switches. If the material reverses in the moment you tap Record, the start is refused ("the travel direction just changed… Tap Record again"). A recording keeps the direction it started with until Stop, and its summary says "Travel direction … detected automatically from the material's movement." **Right → Left** / **Left → Right** set the direction by hand (the readout says *set by hand*); use them when Auto cannot see the movement.
  - **Map: single frame** builds the map from one LiDAR reading per cell, with no averaging between frames, and switches **Raw LiDAR depth** on (Apple's filter smooths over time, which smears moving material). Each cell takes the reading from the frame in which that spot passed closest to the centre row of the LiDAR view. A single-frame map shows the LiDAR's real per-reading noise and its laser-spot spacing (≈ 5 cm at 1 m); it does not resolve individual strands. For strand-level heights use **Map: camera parallax**.
  - **Map: camera parallax** builds the map from the video: how far each small patch of the surface moves between two frames a third of the picture apart gives its height (higher points move more), and the LiDAR sets the scale of every frame pair. It switches the short shutter on and records the video at a higher quality (≈ 300 MB per minute instead of ≈ 120 MB). See *Camera-parallax map*.
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

**How speed is measured**: each video frame is matched against the previous one to find how far the surface texture moved; the LiDAR distance of the tracked area converts pixels to millimetres. The main speed uses a large central area; zone speeds repeat this for each of the 24 zones (128 × 128-pixel templates, up to 320 pixels per frame; zones near the downstream edge match backwards so they have room to search). Speed shows "no texture lock" on blank, featureless surfaces. When you change the direction, or Auto detects a new one, the old speed readings and the travel estimate state are cleared, so they cannot carry into the new direction. While Auto is detecting (no recording running) the main area is searched equally far both ways (up to 480 pixels per frame), so movement either way is seen; during a recording the search runs one way, in the recording's direction, as before. At Record a speed measured in the last 2 seconds is kept, so a short blank stretch at the start of a recording still moves the map on at that speed; an older speed is cleared, and the recording then has zero travel until its first real speed reading. A recording in which no frame got a speed reading says so in its summary: "Speed: no texture lock (map uses zero travel)", or, when a speed from just before Record moved the map, "map travel N mm comes from the speed held from before Record" (a speed at most 2 seconds old; in recordings made before this version, a held speed of any age). The frames and seconds in the summary are counted from `Recording.json` as saved.

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
- With a camera-height or side-wall reference saved in the recording, every value is **height above the belt** (see *Height reference*); with a baseline, every value is **height above the flat surface** (map, statistics prefixed `height_` in TopoStats.csv, profiles, TopoMap.png legend Low → High); without one, values are distances from the camera. **The CV is only defined for distances**: in height mode the mean is near zero, so the CV row is hidden on screen, `height_cv` is blank in `TopoStats.csv` and `cvPercent` is absent from `TopoStats.json`.
- **Rebuild map** reprocesses the saved recording (repairing a cut-off `Recording.json` first and noting it in the summary), keeps the old map on screen while it works, shows "Map not rebuilt: …" if it fails, and updates the scan's summary and file list when it is done ("Map rebuilt, but the scan summary was not updated: …" if that last step fails). All map files are written under temporary names and renamed together at the end, so a failed rebuild never leaves new statistics next to an old picture.
- **Map method** (above **Rebuild map**): *Averaged* (the mean of every reading in a cell), *Single reading* (one reading per cell, nothing averaged) or *Camera parallax* (heights from the video, one reading per cell; see *Camera-parallax map*). Pick one and tap **Rebuild map**; the replay then uses that map. A single-reading LiDAR map also writes `ScanLineProfiles.csv` (one row per frame: the reading on the centre row of the view at each across position; an averaged rebuild removes it) and skips depth frames that only repeat the previous frame (the summary says how many). For single-reading maps the repeat-reading noise is shown as "—" and readings per cell is 1.

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
- On the strip (3D): **drag with one finger to turn it any way**, with no limits: the strip follows your finger (over the top, from below, upside down, full turns). **Twist with two fingers** to roll it, **pinch** to zoom (0.2×–8×; twist and pinch work together), **double-tap** to return to the default view (42° above, square on). The strip turns about the middle of the window and keeps its size while it turns; the lighting turns with the view, so the surface stays readable from any side. **Map** stays the view from straight above.
- **Settings** (slider icon): speed; **target** and **± tolerance** (default = recording median and robust std dev, rounded; Reset button); window length (1–10 × strip width); height scale; smooth surface (3 × 3); tolerance planes on / off; **tilt** (90° = from straight above, −90° = from straight below), **turn** and **roll** (−180° to 180°) for exact angles; **slant** (the sideways shear of the X-ray-style view; 0 = true geometry); zoom; Reset view.
- **Save image** (download icon): PNG of the strip with title, statistics and colour bar, saved as `TopoReplay_<time>s.png` in the scan folder ("Could not save image" with the reason if it fails; "Could not update the scan" if the new file cannot be added to the scan's file list), then the share sheet opens. The file name, the picture and the header all show the same time.

**Notes**
- The map grid is averaged into square blocks for display (at most about 260 blocks along the window and 90 across; the last block row can be narrower) so the strip can be redrawn at every screen refresh. When the block size changes (for example while you drag the window-length slider) the new blocks are built in the background and the current picture stays until they are ready.
- Recordings made before the replay existed have no `TopoGrid.bin`; the first time the replay opens it builds the map (a few seconds). **Rebuild map** on the Topographic map screen also writes it.
- Leaving the screen while it is still loading does not start a replay in the background.

**Expected performance** (from published LiDAR measurements; untested on this app yet): ~15 real LiDAR samples per second (30 depth frames/s delivered), ±1–2 mm height after averaging at ~1 m, real laser-spot spacing ≈ 5 cm across at 1 m; speed ≈ ±0.2–0.3% once the distance scale is checked against a known speed or length.

## Height reference (Line scan)

Heights above the belt need a reference. Tap **Height reference…** on the Line scan screen and pick one; the choice is kept (*Files › On My iPhone › Phone LiDAR › Calibration › HeightReference.json*) and the line under **Height:** shows its state. Without a usable reference the colours and numbers are distances from the camera.

| Reference | Needs | What the app does |
|---|---|---|
| **Empty belt** | The belt clear once | The baseline described above: each depth pixel gets its own zero. Most accurate. |
| **Camera height** | A tape measure | Heights = camera height − distance along the belt normal. The belt is taken as flat. |
| **Side walls** | The wall height above the belt | The LiDAR measures both wall tops; with the wall height this gives the belt, without clearing it. The belt is taken as flat; maps keep only the part between the walls. |

**Camera height**
1. Measure from the camera lens straight down to the belt (mm), type it under *Camera height* and tap **Set**.
2. Level: lay the phone flat (screen up) on the belt and tap **Zero here** on the Line scan screen, then mount it. The belt normal is then taken from the phone's tilt relative to that zero. Without a zero, gravity is used, so the belt must be level ("Level not zeroed…" reminds you).
3. Accuracy: the tape error of the camera height (±5 mm with care) plus the LiDAR's own distance error at the mat.

**Side walls**
1. Measure the wall top above the belt (±1 mm), type it under *Wall height* and tap **Set** (one height for both walls).
2. In the live depth picture of the sheet, drag the orange **Top wall** and **Bottom wall** bands onto the wall tops (the closest surfaces, dark red, near the top and bottom of the picture). **Band width** sets both bands. The wall tops must be wider than about two LiDAR spots: ≈ 10 cm at 1 m, ≈ 30 cm at 3 m.
3. Keep the phone still and tap **Calibrate on the side walls** (90 frames, about 3 s; flakes on the belt do not matter). The sheet shows the belt distance, each wall's distance, readings and spread, and how much the two walls differ.
4. Warnings: the walls differ by more than 5 mm (check the level zero, the wall height and that each band is on a wall top), the phone tilt changed more than 0.3° since the calibration, another depth filter setting, or the bands moved since the calibration — calibrate again. A band with too few steady readings, or no wall height, is refused with the reason. A new wall height is applied without a new calibration (the wall distances stay valid).
5. Zero the level as for *Camera height* if the belt is not level across.
6. Accuracy: wall height ±1 mm plus the averaged wall-top distance (±1–2 mm) plus the LiDAR's small difference between the picture edges and the middle; the LiDAR's own distance error largely cancels because walls and mat are measured by the same sensor.

With *Camera height* or *Side walls* the live overlay, legend, centre height and σ are heights above the belt. At Record the reference (with the level zero in use) is copied into the recording as `HeightReference.json`; every map built from it (Averaged, Single frame, Camera parallax) gives heights above the belt, the summary says "Height above the belt …" and adds a "Height reference: …" line. A reference that is not set up when you record adds a line to the summary and the map shows distances. Playback still shows distances for these recordings.

## Camera-parallax map (Line scan)

The LiDAR's spots are ≈ 5 cm apart at 1 m, so a LiDAR map cannot show single strands. The camera can: as the material moves, a patch of the surface that sits higher (closer to the camera) moves more pixels than one lower down. The app compares each patch in two frames a third of the picture apart, so the "baseline" between the two views is ≈ 0.32 × the camera height, and the LiDAR fixes the scale of every frame pair, so errors in the measured belt speed cancel. No extra hardware is needed.

**Recording**
- Pick **Map: camera parallax** before Record (short shutter switches on). Use good, even light; the wood texture must be sharp.
- Mount as for any Line scan. Strand-level detail needs the camera at about 1 m (≈ 11 mm patches, points every ≈ 5 mm across 1.27 m); at 2.9 m (a 12 ft line from one phone) the patches are ≈ 31 mm.
- Choose a height reference first (see above).
- After Stop the map is built from the video; this takes longer than a LiDAR map (a progress bar shows on the Topographic map screen when you rebuild). **Map method › Camera parallax** + **Rebuild map** builds it from any recording that has `Video.mov` (older recordings have no lens calibration and less video quality, so their heights are less accurate toward the picture edges; the summary says so).

**What is measured**: per patch (16 × 16 pixels, every 8 pixels across, rows every 8 pixels along), one reading per map cell, nothing averaged between frames. The summary line "Camera parallax: …" gives the frame pairs scaled by the LiDAR, the points, the share of patches matched and the LiDAR scale relative to the recorded travel. If nothing could be measured the map is not built and the message says why (no movement of a third of the picture, no texture, no LiDAR readings, or no video).

**Expected performance** (calculated; untested on the device yet): height of a point relative to its neighbours ≈ 0.2–0.6 mm at 1 m, 0.3–0.9 mm at 1.5 m, 0.6–1.8 mm at 2.9 m; the absolute level comes from the LiDAR and the height reference. Strand edges that hide part of a patch from one of the two views give no reading.

## Remote control from a second phone (Line scan)

A second iPhone running Phone LiDAR controls a mounted Line scan phone, for mounts that are hard to reach. The two phones talk over a direct phone-to-phone Wi-Fi link: no router, Wi-Fi network or internet is needed, but **Wi-Fi must be switched on in Settings on both phones** (being joined to a network does not matter). The second phone needs no LiDAR.

**Set up once**
1. On the **scanner** (the mounted phone): open **Line scan**, tap the antenna button next to **Close**, turn on **Allow remote control**, then tap **Pair a remote**. A 6-digit code shows for 5 minutes.
2. On the **remote** (the phone in your hand): Home › **Remote link** › **Control a scanner phone**. The scanner appears under **Scanners nearby** with its name (for example "iPhone 1A2B"); tap it and enter the code.
3. Both phones show **Connected to …**, and the scanner's Remote settings show your phone's name (the remote screen shows it as **This phone**) as the **Paired remote**. The pairing is kept: from now on the remote connects by itself whenever both phones have the app open. A wrong code is refused; one pairing attempt runs at a time, after a wrong code the scanner waits 2 s before it accepts another try, and every 5 wrong codes it shows a new code. If more than one phone answers with the scanner's name (also as "… (2)"), pairing is refused until only the scanner is advertising. **Forget** (scanner sheet, or the **…** menu on the remote) removes the pairing.
4. If iOS asked about the local network and **Don't Allow** was tapped, both screens say "Local Network access is off for Phone LiDAR": turn it on in **Settings › Privacy & Security › Local Network**.

**Using it**
- Leave the scanner on the Line scan screen (mounted, levelled, calibrated as usual). The screen stays awake; a chip under the top bar shows **Remote: …** and the antenna button turns green when the remote is connected.
- On the remote: **Start** and **Stop** work exactly like the scanner's record button. Every command is answered: "Recording started.", "Recording stopped: the scanner is saving it.", or "Refused: …" with the scanner's reason (too hot, not enough storage, still calibrating, Line scan not open). "No answer from the scanner." appears after 5 s without an answer.
- **Scanner readouts** on the remote, 4 times per second: state (Ready, ● REC m:ss · frames, Saving, Building map), speed (mm/s, m/min, ft/min), texture lock, distance, height above the baseline when calibrated, baseline, bubble level, heat, free storage and battery, plus the scanner's warnings and its last message.
- While remote control is allowed, the scanner's Line scan screen **stays open after each save** ("Saved "…". Ready for the next recording.") so the next recording can be started from the remote. Without remote control it opens the scan as before.
- The remote screen keeps the remote phone awake while it is open. **Close** returns to Home and keeps the link (and any copy) running while the app is open, so you can open a copied scan and come back; **…** › **Turn the remote link off** stops it.

**When the link drops** (out of range, steel in the way, the remote phone locked)
- The scanner **keeps recording**, saving and building the map as if nothing happened; all data stays on the scanner. (Locking the scanner phone itself or switching to another app on it still stops and saves the recording, as it always has: iOS stops the camera.)
- Both phones say "Link lost (…)". The remote retries by itself (after 1, 2, 4, then every 5 s) and the scanner keeps waiting for it, so the link comes back without touching either phone once they are in range with the app open (usually within about 15 s). iOS stops the link while the app is in the background (phone locked or another app open) and it reconnects when the app is back on screen.
- No range figure is published for this kind of link; it depends on the two phones and what is between them. Measure it at the mount (P9 test V12 in `docs/implementation-plan.md`).

**Copying scans to the remote for review**
- **Scans on the scanner** lists the scanner's saved Line scans with date and size (a recording that is still being saved or built appears once it is done). Tap **Copy to this phone**. The copy shows MB copied, the rate and the time left; map and statistics files come first, `Depth.bin` and `Video.mov` last (about 120 MB of video per recorded minute plus the depth data).
- When it finishes, the scan is added to the remote's **Saved scans** with the scanner's name, date and summary plus "Copied from <scanner> on <date>.", and opens with the normal **Topographic map**, **Topographic replay** and **Playback** screens. **Open** jumps to it.
- A copy **pauses while the scanner records, saves or builds a map** and continues afterwards; a dropped link pauses it and it continues from where it stopped after reconnecting. If the remote app was closed, the scan shows **Partly copied (N %)** with **Resume** and **Discard**. **Stop copy** pauses it by hand. A file that changed on the scanner since the copy started (for example after **Rebuild map**) is copied again.
- The remote checks its free storage first (the remaining size plus 500 MB). Partial copies are kept out of the library until every file is complete. A copy also pauses while the remote phone itself records a Line scan.
- **Partly copied scans** lists partial copies the paired scanner does not offer now (deleted there, a different scanner paired, or not in its list); **Discard** frees their space.

**Security**: after pairing, the phones only talk to the phone they are paired with. Every connection is checked with the 256-bit pairing key and all traffic is encrypted, so other phones nearby cannot start or stop a scan or copy files. Limit of the pairing step: a phone running modified software that pretends to be the scanner while you pair can work out the 6-digit code from that one attempt and pair in your place. So pair where no such phone is around. After pairing, your phone must show **Connected to** the scanner with its readouts; if your phone reports that pairing failed while the scanner shows a paired remote, tap **Forget** on the scanner and pair again. The paired-remote name on the scanner is only a weak check: a modified phone can copy your phone's name.

## Opening scans on Windows

- `.obj` / `.ply`: Blender, MeshLab, CloudCompare, Autodesk tools.
- `.usdz`: Blender (File › Import › Universal Scene Description), NVIDIA Omniverse.
- `.csv`: Excel. `TopoMap.csv`: rows = across the material (top → bottom of the screen, mm from the image centre line), columns = along the travel (mm from the left edge of the map), values = height above the baseline in mm when the recording has one, otherwise distance from the camera in mm (blank = no data). The map is trimmed to the measured area, so the first column and the first row are the first with data.
- `RoomReport.csv`: the element table (header `type,category,number,width_m,…,confidence`, one row per wall, door, window, opening, floor and object) is followed by an empty line and a **totals block** with its own header `summary_item,value,unit`: `wall_count` (count), `total_wall_length` (m and ft_in), `wall_height_max` (m and ft_in; left out when there are no walls), `floor_area` (m2 and ft2). Excel shows both tables on one sheet; filter on the first column to use the element table alone.
- `TopoStats.csv`: `metric,value,unit` rows. The `values` row says what the numbers are: `height_above_flat_baseline`, `height_above_belt_camera_height`, `height_above_belt_side_walls` or `distance_from_camera`. In height mode `height_cv` is blank. `map_length`, `map_width`, `coverage` and the profile files describe the measured (trimmed) area. `TopoStats.json` is the same data (`cvPercent` is absent in height mode).
- `TopoGrid.bin`: the stitched grid used by the replay. Header (little endian): `PLTG`, version (UInt32, must be 1), columns, rows (UInt32), cell size, qMin, xMin (Float64, mm), height mode (UInt32, 1 = heights above the baseline, 0 = distances from the camera), reserved (UInt32); then rows × columns Float32 values in mm, row-major (rows = across the material top → bottom of the screen, columns = along the travel left → right), NaN = no data. Same cells as `TopoMap.csv` (the trimmed map; the file is refused if it has more than 3,000,000 cells).
- `TopoReplay_<time>s.png`: saved replay images (time = replay time in seconds).
- `Baseline.bin`: width × height Float32 distances (mm) of the empty flat surface per depth pixel; `Baseline.json` holds its size, date, distance, spread before/after correction, coverage and tilt at calibration.
- `Frames.csv` and `ZoneSpeeds.csv`: written line by line while recording. `ZoneSpeeds.csv`: one row per frame, one column per zone (`zone{n}_across{c}_along{r}_mm_s`; across 0 = top of the screen, along 0 = right edge), mm/s, + = travel direction. After a recording that was cut off by a crash, up to about the last 64 kB of these files (and of `Recording.json`) may be missing, so they can end earlier than `Depth.bin` and their last line can be incomplete; the app only uses `Recording.json` and `Depth.bin`.
- `.mov`: any video player (HEVC). It is written in 5-second movie fragments, so a video cut off by a crash plays up to its last complete fragment.
- `Depth.bin`: header `PLDP`, version, width, height (UInt32 LE), then per frame a UInt32 byte count + LZFSE-compressed UInt16 distances in 0.1 mm (0 = no data, also 0 for 6.5 m and farther). A cut-off last frame is ignored; a header with a width or height above 8192 is refused. Frame times, speeds and depth intrinsics are in `Recording.json`.
- `Recording.json`: plain JSON, one object per frame. It is written while recording, so it is compact (not pretty-printed, keys not sorted): the first line holds the settings (`depthWidth`, `depthHeight`, `videoWidth`, `videoHeight`, `filteredDepth`, `shortShutter`, `direction`, `tileColumns`, `tileRows`, and when set `mapMethod` and `lens`, the camera's lens-distortion tables) followed by `"frames":[`, then one frame per line, and `]}` at the end. Any JSON parser (Python `json`) reads it; recordings from earlier versions are pretty-printed with the same keys. A cut-off file is repaired by the app (complete frame lines kept, `]}` added).
- `HeightReference.json`: the height reference copied into a recording (`method` `cameraHeight` or `sideWalls`, `cameraHeight` mm, `wallHeight` mm, the wall bands as fractions of the picture from the top, the wall calibration with each wall top's distance along the belt normal in mm, and the level zero in degrees).
- `ScanLineProfiles.csv` (single-reading LiDAR maps): `frame,time_s,travel_mm,repeated`, then one column per map row (across position in mm). Each row is one frame's reading on the centre row of the LiDAR view at each across position (height or distance, mm; blank = none); `repeated` = 1 for a depth frame identical to the previous one (not used in the map).
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
