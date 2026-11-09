# Phone LiDAR — iPhone LiDAR scanner built without a Mac

You need a Windows PC, a LiDAR iPhone (12 Pro / Pro Max or a newer **Pro** model, iOS 17+), a USB cable and a free GitHub account. The app is compiled on Apple hardware rented by GitHub Actions (`macos-26` runner with Xcode 26).

## What the app does

| Mode | Apple framework | Output files |
|---|---|---|
| **Room scan** | RoomPlan | `Room.usdz` (walls/doors/windows/furniture as boxes), `RoomMesh.usdz`, `CapturedRoom.json`, `RoomReport.csv` (every wall, door, window, object with W × H × D in m and ft-in, floor area, wall length) |
| **Equipment scan (LiDAR mesh)** | ARKit scene reconstruction | `Mesh.usdz`, `Mesh.obj`, `Mesh.ply` (world-space, metres, Y up), `Measurements.csv` from live point-to-point measuring |
| **Object capture** | RealityKit Object Capture + on-device photogrammetry | `Model.usdz` (photo-textured, real scale), `Images/` folder with the source photos |

Every scan can be:
- opened in the built-in 3D viewer (orbit, zoom, pan, tap two points to measure on the model),
- opened in **AR Quick Look** to place the model at 1:1 scale and walk around it,
- shared (AirDrop, Mail, OneDrive, Google Drive) or pulled from the Files app: *On My iPhone › Phone LiDAR › Scans*.

## Folder layout

```
project.yml                     XcodeGen spec (the .xcodeproj is generated on the build Mac)
Support/Info.plist              App settings (camera permission, Files-app access)
PhoneLidar/App/                 App entry + home screen
PhoneLidar/Room/                RoomPlan scanning + CSV report
PhoneLidar/Mesh/                LiDAR mesh scanning, AR measuring, OBJ/PLY/USDZ export
PhoneLidar/Object/              Object Capture + photogrammetry
PhoneLidar/Viewer/              SceneKit 3D viewer with measuring
PhoneLidar/Library/             Scan detail / share / rename / delete
PhoneLidar/Storage/             Scan storage, unit formatting, CSV
.github/workflows/ios-build.yml Cloud build (unsigned .ipa, optional TestFlight upload)
```

---

## Step 1 — Put the code on GitHub (one time)

1. Sign in at github.com → **New repository** → name it `PhoneLidar` → Private or Public → **Create repository**.
   - Public repos get unlimited free macOS build minutes. Private repos get 2,000 included minutes a month, and macOS minutes count 10×, so about 200 real minutes (roughly 20 builds).
2. On the new repo page click **uploading an existing file**.
3. In Windows Explorer open the unzipped `PhoneLidar` folder, select **everything inside it** (including the `.github` folder) and drag it onto the browser page. Click **Commit changes**.
   - Check that `.github/workflows/ios-build.yml` appears in the repo. If the browser skipped the `.github` folder, use **Add file › Create new file**, type `.github/workflows/ios-build.yml` as the name and paste the file's contents.
   - Alternative: install GitHub Desktop, clone the repo, copy the files in, commit and push.

## Step 2 — Build the app in the cloud

1. Open the repo's **Actions** tab. If asked, click **I understand my workflows, go ahead and enable them**.
2. Pick **Build iOS app** → **Run workflow** → **Run workflow**. (Every push to `main` also starts a build.)
3. Wait for the green check (about 5–10 minutes).
4. Open the finished run, scroll to **Artifacts**, download `PhoneLidar-unsigned-ipa-N`. It is a zip containing `PhoneLidar-unsigned-N.ipa`; unzip it.

If the build fails, the run's summary page lists the compiler errors, and the `build-log-N` artifact holds the full log.

## Step 3A — Install for free with Sideloadly (free Apple ID, re-sign every 7 days)

1. On Windows install **iTunes from apple.com** (the Microsoft Store version does not work with Sideloadly) and **Sideloadly** from sideloadly.io.
2. Plug in the iPhone, unlock it and tap **Trust This Computer**.
3. Open Sideloadly, drag the `.ipa` onto it, enter your Apple ID, click **Start**, enter the password / 2FA code when prompted.
4. On the iPhone:
   - **Settings › General › VPN & Device Management** → tap your Apple ID → **Trust**.
   - **Settings › Privacy & Security › Developer Mode** → On → restart → confirm.
5. Launch **Phone LiDAR** and allow camera access.

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
   Press Enter twice for an empty passphrase. This creates `cert_key` (private key) and `cert_key.pub` (not needed).
6. In the GitHub repo: **Settings › Secrets and variables › Actions › New repository secret**, add four secrets:

   | Name | Value |
   |---|---|
   | `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from step 4 |
   | `APP_STORE_CONNECT_KEY_IDENTIFIER` | Key ID from step 4 |
   | `APP_STORE_CONNECT_PRIVATE_KEY` | Full text of `AuthKey_XXXX.p8` (open in Notepad, copy everything including the BEGIN/END lines) |
   | `CERTIFICATE_PRIVATE_KEY` | Full text of `cert_key` from step 5 |

Each release:

1. **Actions › Build iOS app › Run workflow**, tick **Also sign and upload to TestFlight**, run.
2. After the run finishes, App Store Connect processes the build (5–30 minutes).
3. **App Store Connect › your app › TestFlight › Internal Testing › +** → create a group, add yourself. Install the **TestFlight** app on the iPhone and install Phone LiDAR from there.

The signing step uses Codemagic's open-source CLI tools (`codemagic-cli-tools` on PyPI) to create the distribution certificate and provisioning profile through the App Store Connect API, so no Mac Keychain is involved.

---

## Scanning tips

- **Room scan**: start facing a wall, move slowly around the perimeter, tilt up and down to catch doors, windows and furniture. Tap **Done scanning**, wait for the model, then **Save scan**.
- **Equipment scan**: hold the phone 0.5–3 m from the surface (LiDAR range is about 5 m). Sweep until the coloured mesh overlay covers everything. To measure, aim the centre crosshair and tap **Set start point**, then **Set end point** (tapping the screen works too). Undo removes the last point or measurement. The eye button hides the mesh overlay.
- **Object capture**: works best on objects from about 10 cm up to a few metres with texture and even lighting. Tap **Detect object**, fit the box, **Start capture**, walk three loops (low, middle, high), **Finish**. Reconstruction runs on the phone and takes several minutes. On iOS 18+ **Area mode** skips the box for things too large or irregular for one.

## Opening scans on Windows

- `.obj` / `.ply`: Blender, MeshLab, CloudCompare, Autodesk tools.
- `.usdz`: Blender (File › Import › Universal Scene Description), NVIDIA Omniverse.
- `.csv`: Excel.
- Object-capture photos (`Images/`) can be reprocessed on a PC with photogrammetry software such as RealityCapture or Meshroom for higher detail.

## Changing the app

Edit the Swift files (in the GitHub web editor or locally) and push to `main`. Every push triggers a new build and a new `.ipa`. Install it over the old one with Sideloadly (same Apple ID) to keep existing scans.
