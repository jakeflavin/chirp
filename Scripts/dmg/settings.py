# The Chirp.dmg install window, for dmgbuild (Scripts/release.sh). The background and volume icon are the approved
# design; see Scripts/dmg/README.md. Pass the app with: dmgbuild -s Scripts/dmg/settings.py -D app=<Chirp.app> Chirp out.dmg
import os.path

here = os.path.abspath(defines.get("assets", "Scripts/dmg"))  # noqa: F821 (dmgbuild runs this file without __file__)
app = defines["app"]  # noqa: F821 (given by dmgbuild)

format = "ULFO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [os.path.basename(app)]
icon = os.path.join(here, "VolumeIcon.icns")

background = os.path.join(here, "background.tiff")
window_rect = ((200, 160), (660, 420))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
icon_size = 128
text_size = 12
label_pos = "bottom"
arrange_by = None
icon_locations = {
    os.path.basename(app): (170, 200),
    "Applications": (490, 200),
}
