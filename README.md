<p align="center">
  <img src="Resources/AppIcon.png" width="96" alt="SAS.Planet icon">
</p>

<h1 align="center">SAS.Planet for macOS</h1>

This is a macOS version of [SAS.Planet](https://github.com/sasgis/sas.planet.src). It looks and works the same as the Windows version (same menus, toolbars, maps etc.)

This version is made specially for IFAET(Infinite Flight Airport Editing Team). If you encounter any issues please DM me (alexev) on the ifc :)

## Blank image removal

The stitch menu can clean up blank image tiles and export as a .zip (This will save some time when exporting imagery)

- **Remove blank images if ≥ N % blank:** deletes stitched pieces that are mostly or entirely blank along with their `.kml` files.
- **Pack results into a ZIP (for Infinite Flight):** zips everything that's left after removing blank tiles.

Based on the [IFAET Imagery Compiler](https://github.com/alexgankov/IFAET-Imagery-Compiler). All credit to [@Alex](https://community.infiniteflight.com/u/alex/summary) there!

## Install

Compatible with both Apple silicon and Intel running macOS 12 or later.

1. **Download.** Go to the [latest release](../../releases/latest) and download **`SASPlanet-macOS.zip`** (under *Assets*). (There is also a link in the release notes.)
2. **Unzip.** Double-click the downloaded zip in your Downloads folder. A **SASPlanet** app will appear next to it.
3. **Move it to Applications.** Drag **SASPlanet** into your **Applications** folder (in Finder's sidebar).
4. **Opening for the first time** Double-click SASPlanet in Applications. macOS will most likely show a warning that it can't check the app. Click **Done** (or **OK**), then:
   1. Open **System Settings → Privacy & Security**.
   2. Scroll down to the message about SASPlanet and click **Open Anyway**.
   3. Confirm with **Open Anyway** again (and your password or Touch ID if asked).
5. **Done.** The app is now ready to use, when you return to **Applications**, the app will now open normally.

### Updating

Download the new release and drag it into Applications, choosing **Replace**. Your cache and settings will be kept.

## Not available yet

- Placemarks
- GPS
- Favorites
- Garmin JNX and IMG export
- Yandex maps, and other map sources that use a different projection or need an API key

## Feedback

If you encounter any issues, or have feedback/feature requests please send me a DM on either discord or the IFC. (@alexev for both platforms.)

## Credits

Based on [SAS.Planet](https://github.com/sasgis/sas.planet.src) by the SAS.Planet development team, and released under [GNU GPL v3](LICENSE) licence. Not affiliated with Infinite Flight, the SAS.Planet team or any map provider.
