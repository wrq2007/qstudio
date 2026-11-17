# -*- coding: utf-8 -*-
"""dmgbuild 的排版设置：图标位置、窗口大小、背景图。
由 Tools/make_dmg.sh 调用，app 路径通过 -D app=... 传入。"""

import os

app = defines.get("app")            # noqa: F821  dmgbuild 注入
resources = defines.get("resources")  # noqa: F821

volume_name = defines.get("volname", "Q Studio")  # noqa: F821
format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}

# 背景图：左边放 app，右边放 Applications，箭头正好在两者之间
background = os.path.join(resources, "dmg-background.png")

# 窗口位置与大小（左上角坐标 + 宽高）
# 高度 428 = 背景图 400 + 标题栏 28：写成 400 时内容区只剩 372，
# 背景图底部那行「首次打开…右键打开」会被裁掉。
window_rect = ((240, 160), (640, 428))


# 图标位置用「左上角为原点」的坐标，和背景图上画的位置对应
icon_locations = {
    "Q Studio.app": (150, 176),
    "Applications": (490, 176),
}

default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 108
text_size = 13
label_pos = "bottom"
arrange_by = None
grid_offset = (0, 0)
scroll_position = (0, 0)
