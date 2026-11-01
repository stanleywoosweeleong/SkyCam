# SkyCam for iPhone (native) — build and install guide

No Mac and no paid Apple developer account needed. GitHub builds the app for free; Sideloadly installs it on an
iPhone from a Windows PC with a free Apple ID.

## 1. How the native app works

| Layer | What it does | Where it lives |
|---|---|---|
| **Web UI** | The same SkyCam screen (GND editor, looks, settings, album), running inside a native app window, with the live preview | `index.html` (one file shared by the website and the app) |
| **Native shell** | Native iPhone app that loads the bundled web UI and lets it call native code | `ios/SkyCam/WebViewController.swift` |
| **Native camera** | When you press the shutter, the web preview releases the camera and the iPhone's photo camera takes **3 full-quality exposures (−2, 0, +2 EV)** | `ios/SkyCam/NativeCamera.swift` |
| **Image processing** | Lines the frames up, merges them into HDR, crops to your frame shape, then applies the GND filters, white balance and sky look | `ios/SkyCam/SkyProcessor.swift`, `SkyKernels.metal` |
| **Output** | Saves the full-quality photo (HEIF) to the **Photos app**, plus a small copy in SkyCam's album | `PhotoSaver` in `NativeCamera.swift` |

The web page detects when it's running inside the app (`NATIVE` in `index.html`); in Safari it behaves exactly as
before. The photo processing uses the same maths as the web preview, so the saved photo matches what you framed.
Long exposures still use the live preview frames.

## 2. Building it without a Mac (free)

iOS apps must be compiled on macOS; GitHub provides free macOS build machines for public repos.

- **The build file:** `.github/workflows/ios.yml` tells GitHub how to build the app.
- **What triggers it:** every push to `main` that changes `index.html` or anything in `ios/` starts a build
  (about 3–5 minutes). It can also be started by hand: **Actions → iOS app → Run workflow**.
- **What it does:** copies the web files into the app, generates the Xcode project from `ios/project.yml`
  (with XcodeGen), compiles it without signing, and packages **`SkyCam.ipa`**.
- **Where to get the file:** **Actions → iOS app → latest run → Artifacts → SkyCam-ipa**. Download and unzip it.

The app is deliberately left unsigned at this stage; Sideloadly signs it with your Apple ID when you install it.

## 3. One-time setup on the Windows PC

| Needed | Notes |
|---|---|
| **iTunes** (apple.com version, not Microsoft Store) | Provides the iPhone drivers |
| **Apple Mobile Device Support** | Installed with iTunes; its service must be running |
| **iCloud for Windows (non-Store)** | Use the link on **sideloadly.io** — Apple's own page only offers the Microsoft Store version, which Sideloadly can't use |
| **Sideloadly** | From https://sideloadly.io — keep it updated for the newest iPhones and iOS |
| **iPhone trusts the PC** | Plug in, unlock, tap **Trust** and enter your passcode (once) |

## 4. Installing on the iPhone with Sideloadly

1. Plug the iPhone in with a USB cable and unlock it. Open Sideloadly *after* the phone is connected.
2. Choose your iPhone in the **iDevice** dropdown.
3. Drag **SkyCam.ipa** into Sideloadly and enter your **Apple ID**.
4. Press **Start**. Enter your Apple ID password (and a 2-factor code if asked) in Sideloadly yourself, then wait for "Done".
5. On the iPhone, the first time only:
   - **Settings › Privacy & Security › Developer Mode** → On → restart → confirm.
     This option only appears after the first sideloaded app is installed.
   - **Settings › General › VPN & Device Management** → your Apple ID → **Trust**.
6. Open SkyCam, then allow **Camera** and **Add to Photos**.

## 5. Free Apple ID rules

- **7 days:** the app stops opening after a week. Plug in and press **Start** in Sideloadly again.
  Your settings, in-app album and photos in the Photos app are kept.
- At most **3 sideloaded apps** at once per free Apple ID.
- **Cost: $0.** The $99-a-year Apple developer membership would only remove the 7-day limit and allow TestFlight
  or the App Store.

## 6. Updating the app

1. Push the changed code to `main`. That rebuilds the app automatically and also updates the website version
   (GitHub Pages).
2. Download the new **SkyCam.ipa** from Actions.
3. Sideload it the same way. It installs over the old version and keeps your data.

## 7. Troubleshooting

| Problem | Fix |
|---|---|
| Sideloadly says "no devices detected" | Unlock the phone; restart Sideloadly with the phone plugged in; try another USB port (not a hub); update Sideloadly |
| Apple ID or signing errors | Install the **non-Store** iCloud for Windows from sideloadly.io's links, then restart the PC |
| "Untrusted Developer" when opening SkyCam | Settings › General › VPN & Device Management → Trust |
| Developer Mode is missing | It appears only after the first sideload; install once, then turn it on |
| App won't open after a week | Normal for a free account; re-sideload |
| Shutter pressed but no photo / an error | Note the message and what happened, and report it as an issue on the repo |

## 8. Building on a Mac instead (optional)

```bash
brew install xcodegen
```
```bash
mkdir -p ios/www && cp index.html manifest.webmanifest icon.svg icon-*.png apple-touch-icon.png ios/www/
```
```bash
cd ios && xcodegen generate && open SkyCam.xcodeproj
```

Then in Xcode choose your iPhone and press Run. This works with the same free Apple ID and the same 7-day rule.
