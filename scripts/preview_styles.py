# -*- coding: utf-8 -*-
"""
拼一张「球样式对照图」给自己/用户看效果（不参与打包，产物在 ref/ 下，已 gitignore）。

用法：
    python scripts/preview_styles.py
产出：
    ref/style_preview.png   三列（三个样式）× 两行（浅色底 / 深色底）

为什么要浅色 + 深色两行：球是半透明的，只有在两种底上都看清才知道能不能用。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_icon as mk  # noqa: E402

STYLES = ["BallDot", "BallPlain", "BallWhite"]
CELL = 200          # 每格边长
GAP = 16
MARGIN = 20
LIGHT_BG = (238, 239, 242)
DARK_BG = (27, 29, 34)

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                   "ref", "style_preview.png")


def main():
    width = MARGIN * 2 + len(STYLES) * CELL + (len(STYLES) - 1) * GAP
    height = MARGIN * 2 + 2 * CELL + GAP
    rgba = bytearray(width * height * 4)

    # 背景：上一行浅色，下一行深色
    split = MARGIN + CELL + GAP // 2
    for y in range(height):
        bg = LIGHT_BG if y < split else DARK_BG
        rgba[y * width * 4:(y + 1) * width * 4] = bytes((bg[0], bg[1], bg[2], 255)) * width

    for row in range(2):
        for col, name in enumerate(STYLES):
            cx = MARGIN + col * (CELL + GAP) + CELL / 2.0
            cy = MARGIN + row * (CELL + GAP) + CELL / 2.0
            mk.draw_dot(rgba, width, height, cx, cy, CELL * 0.62, mk.STYLES[name])

    os.makedirs(os.path.dirname(os.path.abspath(OUT)), exist_ok=True)
    mk.write_png(os.path.abspath(OUT), width, height, rgba)
    print("已生成：%s  %dx%d" % (os.path.abspath(OUT), width, height))
    print("列顺序：%s（上排浅色底 / 下排深色底）" % " / ".join(STYLES))


main()
