# SkyCam for iPhone (native)

The same SkyCam screen, but the shutter uses the iPhone's real photo camera: three full-quality exposures
(−2, 0, +2 EV) are lined up, merged into HDR, your GND filters and sky look are applied, and the photo is
saved to the **Photos** app. Long exposures still use the live preview frames.

No Mac and no paid Apple developer account needed.

## Get the app file

Every push to `main` builds it automatically on GitHub's free macOS machines:
**Actions → iOS app → latest run → Artifacts → SkyCam-ipa**. Unzip it to get `SkyCam.ipa`.

## Install on your iPhone from a Windows PC (free Apple ID)

1. Install **iTunes** and **iCloud** for Windows from apple.com (the website versions, *not* the Microsoft Store ones).
2. Install **Sideloadly** from https://sideloadly.io.
3. Connect the iPhone with a USB cable, unlock it, and tap **Trust** on the phone.
4. Open Sideloadly, drag `SkyCam.ipa` in, type your Apple ID, press **Start**, and enter your Apple ID password
   when Sideloadly asks (it signs the app with Apple's free developer service).
5. On the iPhone:
   - **Settings › Privacy & Security › Developer Mode** → On, then restart the phone and confirm.
   - **Settings › General › VPN & Device Management** → tap your Apple ID → **Trust**.
6. Open SkyCam and allow the camera and adding photos.

## The free-account rules

- The app stops opening after **7 days**. Plug the phone in and press Start in Sideloadly again;
  your settings and in-app album are kept. Photos already saved to the Photos app are never affected.
- A free Apple ID can have at most 3 sideloaded apps at once.

## Build it yourself on a Mac (optional)

```bash
brew install xcodegen
mkdir -p ios/www && cp index.html manifest.webmanifest icon.svg icon-*.png apple-touch-icon.png ios/www/
cd ios && xcodegen generate && open SkyCam.xcodeproj
```
