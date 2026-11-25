# dmgbuild 的安装盘布局：小窗口里左边 Tacit、右边“应用程序”，中间是背景上的箭头。
# 由 scripts/release-dmg.sh 调用：dmgbuild -s scripts/dmg-settings.py -D app=<Tacit.app> -D background=<背景 png> <卷名> <输出>
import os.path

app = defines["app"]  # noqa: F821  dmgbuild 注入
format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {os.path.basename(app): (160, 190), "Applications": (480, 190)}
background = defines["background"]  # noqa: F821
window_rect = ((200, 160), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
