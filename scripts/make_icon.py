# -*- coding: utf-8 -*-
"""
生成 App 图标（不依赖任何第三方库，自己写 PNG）。

⚠️ 为什么不用 AppKit/CoreGraphics 画：
   默认项目里踩过这个坑 —— 裸命令行脚本里画图没有建立图形上下文，
   绘制会**静默无效**，最后存出一张全透明 PNG，桌面上就是个空白图标。
   所以这里逐像素算，画完还会自检「是不是真有内容」。

产出：
    layout/Applications/FloatingBall.app/AppIcon60x60@2x.png  (120x120)
    layout/Applications/FloatingBall.app/AppIcon60x60@3x.png  (180x180)
"""
import os
import struct
import zlib

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                       "layout", "Applications", "FloatingBall.app")


def write_png(path, width, height, rgb_rows):
    """rgb_rows: list of bytes, 每行 width*3 字节（RGB，无 alpha）"""
    raw = b"".join(b"\x00" + row for row in rgb_rows)

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8bit, color type 2 = RGB
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def render(size):
    """深色底 + 中间一个白球，3x3 超采样做抗锯齿"""
    ss = 3
    r = size * 0.30          # 球半径
    cx = cy = size / 2.0
    # 背景竖渐变
    top = (26, 30, 42)
    bottom = (48, 56, 78)

    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            # --- 背景（平铺，直接算，不用超采样）---
            t = y / max(1, size - 1)
            br = int(top[0] + (bottom[0] - top[0]) * t)
            bg = int(top[1] + (bottom[1] - top[1]) * t)
            bb = int(top[2] + (bottom[2] - top[2]) * t)

            # --- 球：超采样求覆盖率 ---
            inside = 0
            for sy in range(ss):
                for sx in range(ss):
                    px = x + (sx + 0.5) / ss
                    py = y + (sy + 0.5) / ss
                    dx = px - cx
                    dy = py - cy
                    if dx * dx + dy * dy <= r * r:
                        inside += 1
            cover = inside / float(ss * ss)

            if cover <= 0.0:
                row += bytes((br, bg, bb))
            else:
                # 球色：左上有高光，右下略暗
                u = (x - (cx - r)) / (2 * r)
                v = (y - (cy - r)) / (2 * r)
                shade = 1.0 - 0.28 * max(0.0, min(1.0, (u + v) / 2.0))
                sr, sg, sb = int(248 * shade), int(250 * shade), int(252 * shade)
                row += bytes((int(br + (sr - br) * cover),
                              int(bg + (sg - bg) * cover),
                              int(bb + (sb - bb) * cover)))
        rows.append(bytes(row))
    return rows


def self_check(rows, size):
    """⚠️ 一定要自检，否则会静默产出空白图"""
    colors = set()
    for row in rows:
        for i in range(0, len(row), 3):
            colors.add(row[i:i + 3])
    if len(colors) < 50:
        raise SystemExit("自检失败：颜色数只有 %d，图标可能是空白" % len(colors))
    # 再确认中间真的比边角亮（球画上去了）
    mid = rows[size // 2]
    mid_px = mid[(size // 2) * 3:(size // 2) * 3 + 3]
    corner = rows[2][6:9]
    if sum(mid_px) <= sum(corner):
        raise SystemExit("自检失败：中心不比边角亮，球没画上去")
    return len(colors)


def main():
    out = os.path.abspath(OUT_DIR)
    os.makedirs(out, exist_ok=True)
    for scale, name in ((2, "AppIcon60x60@2x.png"), (3, "AppIcon60x60@3x.png")):
        size = 60 * scale
        rows = render(size)
        n = self_check(rows, size)
        path = os.path.join(out, name)
        write_png(path, size, size, rows)
        print("%s  %dx%d  %d bytes  颜色数=%d" % (name, size, size, os.path.getsize(path), n))


main()
