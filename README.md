# SAS.Planet for macOS (native port)

A native Swift/AppKit port of [SAS.Planet](https://github.com/sasgis/sas.planet.src), built from its source. It reuses SAS.Planet's menus, shortcuts, toolbar icons, zoom slider, status bar, Selection Manager layout and download logic. GPLv3, like the original.

## Run

Double-click `SASPlanet.app`. To rebuild after changes, run `./build.sh` (it needs Apple's Command Line Tools, which are already installed).

The first time, macOS may block it because it isn't notarised. Right-click it, choose **Open**, then confirm.

## What works

- **Main window**: the SAS.Planet menu bar (Operations, View, Source, Maps, Layers, …) and toolbars (Main, Sources, Placemarks, GPS, Search, Time interval), with the original icons. Also the zoom slider (z1–z24), the status bar (zoom, DMS coordinates, m/pixel, downloaded, queue, tile file path), the scale legend and the overview map.
- **Maps**: Bing (Satellite, Hybrid, Map); ESRI (World Imagery, Street, Topo, National Geographic); Google (Satellite, Map, Landscape, Landscape w/o names, Transit); OSM (Mapnik, Humanitarian, CyclOSM, OpenTopoMap); Carto light and dark. Overlay layers: Google Hybrid, ESRI Boundaries & Places, OpenSeaMap and Waymarked hiking trails. OpenStreetMap's own servers forbid bulk downloading, so downloads from them are capped at 250 tiles.
- **Source modes**: Cache, Internet, and Internet & Cache.
- **Cache**: SAS.Planet's own folder layout (`cache/<folder>/z<zoom+1>/<x/1024>/x<x>/<y/1024>/y<y>.jpg`) with `.tne` markers. Existing SAS.Planet caches work: point **Options** at the cache folder, and use **Settings → Map Settings** if your folder names differ (defaults: `sat`, `map`, `landscape`, `landscape_nn`, `transit`, `both`).
- **Tools**: move (with inertia), mouse-wheel and pinch zoom, distance calculation, circle calculation, Go to (⌘G), and search (OSM or coordinates).
- **View options**: tile boundaries, lat/lon grid, night mode, full screen, and zoom animation.
- **Selection**: rectangle (two clicks or a drag), polygon (click points, then Return or double-click), by coordinates, visible area and last selection. You can load and save SAS.Planet `.hlg` selection files.
- **Selection Manager, Download tab**: all the SAS.Planet options, including start paused, try if tne exists, overwrite (only if different or older than a date), autosave session and split into parts.
- **Download window**: log, progress, pause/resume and session saving. Use **Operations → Open…** to resume a saved session.
- **Selection Manager, Delete tab**: deletes tiles and/or tne markers in the selection.
- **Selection Manager, Stitch tab**: joins the cached tiles of a selection into one image (JPEG, PNG, GeoTIFF, or KMZ for Garmin / Google Earth), optionally with an overlay layer, precise polygon cropping and splitting into parts. It writes SAS.Planet's georeferencing files: OziExplorer `.map`, MapInfo `.tab`, world file `.w` (with `.prj` and `.aux.xml`), `.dat` and `.kml`. The tab shows how many of the needed tiles are cached, and **Download missing tiles…** sets up the download for you. Images are built in strips, so large areas don't need the whole image in memory. GeoTIFF switches to BigTIFF above 4 GB. JPEG is limited to 65,500 px per side.

- **Selection Manager, Export tab**: MBTiles (SQLite, MBTiles 1.3 metadata, TMS or XYZ scheme), with an optional overlay layer and lower-zoom fill-in.
- **Selection Manager, Generate tab**: builds lower zooms from a higher one (optionally each zoom from the previous one), with a choice of resize algorithm, overwrite and complete-tiles-only options.
- **Selection Manager, Copy tab**: copies (or moves) the tiles of one or more maps to a folder in any SAS.Planet cache layout (SAS.Planet, GoogleMV, EarthSlicer, GlobalMapper Tiles/Aux/Bing, MOBAC, OsmAnd, TMS) or to an OsmAnd, Locus or RMaps SQLite database.
- **More export formats**: OruxMaps (SQLite plus `.otrk2.xml` calibration), RMaps, Locus and OsmAnd SQLite, Zip and Tar archives (in any cache naming layout), and Google Earth KML (tiles plus level-of-detail ground overlays).
- **A Message from the Developer** (Help menu): shown once on first launch. Edit `Sources/SASPlanet/DeveloperMessage.swift` to change it.
- **Cached Tiles Map** (View menu or the globe toolbar button): for any zoom, shades the tiles that are missing (black) or marked `.tne` (red) in the cache. It can instead mark existing tiles, or colour them by age, filtered by the Fill From / To dates.

## Not ported yet

Garmin JNX and IMG export; SAS4Android export; placemarks; GPS; favorites; GenShtab grids; other projections; and map sources that use other projections (such as Yandex) or need API keys.

## Keyboard shortcuts

SAS.Planet's own shortcuts work exactly as on Windows (Ctrl = ⌃ Control, Alt = ⌥ Option). The menus also show Mac ⌘ versions. Help → Keyboard Shortcuts lists them all in the app.

| Keys | Action |
|---|---|
| PgUp / PgDn | Zoom in / out |
| Ctrl+G | Go to… |
| Ctrl+L | Distance calculation |
| Alt+R | Rectangular selection (hold Shift to snap to the tile or lat/lon grid) |
| Alt+P | Polygonal selection |
| Ctrl+A | Select the visible area |
| Ctrl+B | Last selection |
| F11 | Full screen |
| Alt+F11 | Hide window borders |
| Alt+S / Alt+M / Alt+L | Status bar / overview map / scale legend |
| Alt+N | Night mode (colour inversion) |
| F1 | Lat/lon grid: auto |
| Alt+C / Alt+I / Alt+B | Source: Cache / Internet / Internet & Cache |
| Ctrl+Alt+P | Map settings |
| G / M / V | Google Satellite / Google Map / Bing Satellite |
| Arrow keys | Move the map (speeds up while held) |
| Delete (⌦) held + click | Delete the tile under the cursor from the cache |
| Insert / Help held + click | Download the tile under the cursor |
| Esc / Enter / Backspace | Cancel drawing / finish polygon / remove last point |

## Mac differences

The menus are in the macOS menu bar. Windows Ctrl shortcuts use ⌘ and Alt shortcuts use ⌥: ⌥R for rectangular selection, ⌘G for Go to, ⌃⌘F for full screen. Two-finger trackpad scrolling pans the map; pinch, the mouse wheel or ⌘+scroll zooms.
