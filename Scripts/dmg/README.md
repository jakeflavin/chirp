# The disk image window

`Scripts/release.sh` builds `Chirp.dmg` with [dmgbuild](https://github.com/dmgbuild/dmgbuild), using `settings.py`. It writes Finder's window layout straight into the image, so no Finder automation is needed.

| File | What |
|---|---|
| `settings.py` | Window 660 × 420 pt, icons 128 pt. Chirp centred at (170, 200), Applications at (490, 200). No toolbar, sidebar, status bar or path bar, and the `.app` extension hidden |
| `background.tiff` | The background at 1× (660 × 420) and 2× (1320 × 840), joined with `tiffutil -cathidpicheck` |
| `background.svg` | Its source |
| `VolumeIcon.icns` | The icon of the mounted disk, 16 to 1024 px |
| `volume.svg` | Its source |

Finder doesn't change the background in dark mode, but it does change the colour of the icon names. Each name sits on a mid-tone tag so it reads in both modes. Nothing important is in the bottom 60 pt, in case the title bar takes some of the window's height.

To change the artwork, edit the SVGs, render each at 1× and 2× (72 and 144 dpi), and join the two with `tiffutil -cathidpicheck background.png background@2x.png -out background.tiff`.
