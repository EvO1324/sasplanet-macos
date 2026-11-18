# Publishing SAS.Planet for macOS

## 1. Build the release zip

```bash
./build.sh --zip
```

This makes `dist/SASPlanet-macOS.zip`. It is a universal app, so it runs on both Apple Silicon and Intel Macs with macOS 12 or later.

## 2. Publish the source code too (required)

SAS.Planet is licensed under GPL v3, and this port reuses its design, icons and logic, so it is GPL v3 as well. If you share the app, you must also share the full source code under the same licence.

The easiest way is GitHub:

1. Create a new public repository, for example `sasplanet-macos`.
2. Upload everything in this folder **except** `.build/`, `dist/` and `SASPlanet.app`. Keep `LICENSE` and `README.md`. Add a `.gitignore` containing those three entries.
3. Keep the credit to the SAS.Planet team (it's in the README, the About box and the welcome message).

## 3. Release the app

On GitHub: **Releases → Draft a new release**, tag it (for example `v0.3`), attach `dist/SASPlanet-macOS.zip`, and in the notes say which macOS versions it needs and how to open it (next section).

Then post the release link wherever your users are (IFC, Discord).

## 4. Gatekeeper: how other people open it

The app is not signed with an Apple Developer ID, so macOS will refuse to open it the first time ("Apple could not verify…"). Choose one of these:

**Free: tell users how to allow it.** Put this in the release notes:

> 1. Unzip and drag **SASPlanet** into **Applications**.
> 2. Open it once. When macOS blocks it, open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**, then confirm.

**Paid ($99/year): sign and notarise it.** This gives a smooth, warning-free install.

1. Join the Apple Developer Program and create a **Developer ID Application** certificate (Xcode → Settings → Accounts → Manage Certificates).
2. Sign:
   ```bash
   codesign --force --options runtime --timestamp -s "Developer ID Application: YOUR NAME (TEAMID)" SASPlanet.app
   ```
3. Zip it and notarise:
   ```bash
   ditto -c -k --keepParent SASPlanet.app SASPlanet-macOS.zip
   xcrun notarytool submit SASPlanet-macOS.zip --apple-id YOU@EXAMPLE.COM --team-id TEAMID --password APP-SPECIFIC-PASSWORD --wait
   xcrun stapler staple SASPlanet.app
   ditto -c -k --keepParent SASPlanet.app SASPlanet-macOS.zip
   ```
   The app-specific password comes from appleid.apple.com.

## 5. Things to tell users

- Their cache goes in `~/SASPlanet/cache`. Caches from SAS.Planet on Windows can be copied there (set the folder in Options).
- Bulk-downloading map tiles may break the providers' terms (Google, Bing, ESRI), and OpenStreetMap's own servers forbid it. Ask users to download responsibly.
- Where to report problems (your IFC / Discord DM, as in the welcome message).

## 6. Updating

Change the version in `build.sh` (`CFBundleShortVersionString`), run `./build.sh --zip`, and publish a new GitHub release. To show an updated welcome message once to everyone, bump `version` in `Sources/SASPlanet/DeveloperMessage.swift`.
