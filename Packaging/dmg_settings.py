# dmgbuild settings for GIFt's disk image: a Finder window with the app beside an Applications
# link and an arrow between them. dmgbuild writes the window layout directly instead of scripting Finder, so
# the image comes out the same on a headless CI runner as on a desk.
#
# scripts/make_dmg.sh passes `app` (the .app path), `icon` (the volume icon), and `background` with
# -D. dmgbuild picks up the background's @2x sibling for Retina screens.

import os.path

application = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(application)

format = "ULFO"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821

window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (170, 190),
    "Applications": (470, 190),
}
