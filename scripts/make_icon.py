# -*- coding: utf-8 -*-
"""
生成 1) App 图标  2) 球本体贴图（多个样式，App 里可切换）。

默认样式照手机自带的「辅助触控」小圆点 ——
半透明深色圆 + 一圈浅色细环 + 中间一个浅色十字（把圆分成四块）。
另外给两个备选：纯色极简、白点（深色背景上用）。

⚠️ 为什么不用 AppKit/CoreGraphics 画：
   默认项目里踩过这个坑 —— 裸命令行脚本里画图没有建立图形上下文，
   绘制会**静默无效**，最后存出一张全透明 PNG，桌面上就是个空白图标。
   所以这里逐像素算，画完还会自检「是不是真有内容」。

产出（都放 layout/Applications/FloatingBall.app/）：
   AppIcon60x60@2x.png  120x120  桌面图标（固定用默认样式）
   AppIcon60x60@3x.png  180x180
   BallDot.png          256x256  默认样式，透明底、满幅（屏幕上球本体用）
   BallPlain.png        256x256  备选：纯色
   BallWhite.png        256x256  备选：白点

⚠️ 设置里存的就是贴图名（BallStyle = BallDot / BallPlain / BallWhite），
   所以「屏幕上的球」和「桌面图标」用的是同一份图，改这里一处就同时改两处。
"""
import os
import struct
import zlib

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                       "layout", "Applications", "FloatingBall.app")

DEFAULT_STYLE = "BallDot"

# 每个样式都以「圆点直径 D」为单位，方便任意缩放
STYLES = {
    # 默认：系统辅助触控小圆点
    "BallDot": dict(
        body_rgb=(0, 0, 0), body_alpha=0.57,
        ring_rgb=(255, 255, 255), ring_alpha=0.42,
        ring_inset=0.075, ring_stroke=0.035,
        cross_rgb=(255, 255, 255), cross_alpha=0.34,
        cross_arm=0.360, cross_stroke=0.032,
    ),
    # 备选 1：纯色极简（一个圆 + 一圈细边）
    "BallPlain": dict(
        body_rgb=(0, 0, 0), body_alpha=0.55,
        ring_rgb=(255, 255, 255), ring_alpha=0.38,
        ring_inset=0.060, ring_stroke=0.040,
        cross_alpha=0.0,
    ),
    # 备选 2：白点（深色壁纸/夜间更显眼）
    "BallWhite": dict(
        body_rgb=(255, 255, 255), body_alpha=0.92,
        ring_rgb=(0, 0, 0), ring_alpha=0.22,
        ring_inset=0.060, ring_stroke=0.035,
        cross_alpha=0.0,
    ),
}

# App 图标的底：很浅的竖渐变（偏 iOS 系统图标那种淡灰）
ICON_BG_TOP = (247, 248, 250)
ICON_BG_BOTTOM = (226, 229, 235)
ICON_DOT_RATIO = 0.62         # 圆点直径 / 图标边长


def write_png(path, width, height, rgba):
    """rgba: bytearray，长度 width*height*4（RGBA，color type 6）"""
    raw = bytearray()
    for y in range(height):
        raw.append(0)                                   # 每行一个 filter byte
        raw += rgba[y * width * 4:(y + 1) * width * 4]

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)  # 8bit RGBA
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def fill_gradient(rgba, width, height):
    """图标底：浅色竖渐变（不透明）"""
    for y in range(height):
        t = y / max(1, height - 1)
        r = int(ICON_BG_TOP[0] + (ICON_BG_BOTTOM[0] - ICON_BG_TOP[0]) * t)
        g = int(ICON_BG_TOP[1] + (ICON_BG_BOTTOM[1] - ICON_BG_TOP[1]) * t)
        b = int(ICON_BG_TOP[2] + (ICON_BG_BOTTOM[2] - ICON_BG_TOP[2]) * t)
        rgba[y * width * 4:(y + 1) * width * 4] = bytes((r, g, b, 255)) * width


def draw_dot(rgba, width, height, cx, cy, diameter, style, ss=3):
    """把圆点画进 RGBA 缓冲。ss = 超采样倍数（抗锯齿）"""
    body_rgb = style["body_rgb"]
    ring_rgb = style["ring_rgb"]
    cross_rgb = style.get("cross_rgb", (255, 255, 255))

    radius = diameter / 2.0
    ring_out = radius - style["ring_inset"] * diameter
    ring_in = ring_out - style["ring_stroke"] * diameter
    arm = style.get("cross_arm", 0.0) * diameter
    half_cross = style.get("cross_stroke", 0.0) * diameter / 2.0
    cross_on = style.get("cross_alpha", 0.0) > 0.0

    x0 = max(0, int(cx - radius - 2))
    x1 = min(width, int(cx + radius + 3))
    y0 = max(0, int(cy - radius - 2))
    y1 = min(height, int(cy + radius + 3))

    tot = float(ss * ss)
    for y in range(y0, y1):
        for x in range(x0, x1):
            n_body = n_ring = n_cross = 0
            for sy in range(ss):
                for sx in range(ss):
                    px = x + (sx + 0.5) / ss - cx
                    py = y + (sy + 0.5) / ss - cy
                    d2 = px * px + py * py
                    if d2 <= radius * radius:
                        n_body += 1
                        if cross_on and ((abs(px) <= arm and abs(py) <= half_cross) or
                                         (abs(py) <= arm and abs(px) <= half_cross)):
                            n_cross += 1
                    if ring_in * ring_in <= d2 <= ring_out * ring_out:
                        n_ring += 1

            # 从下往上叠：圆底 -> 环 -> 十字（都在透明缓冲上合成）
            cr = cg = cb = ca = 0.0
            for rgb, alpha in ((body_rgb, style["body_alpha"] * n_body / tot),
                               (ring_rgb, style["ring_alpha"] * n_ring / tot),
                               (cross_rgb, style.get("cross_alpha", 0.0) * n_cross / tot)):
                if alpha <= 0.0:
                    continue
                na = alpha + ca * (1.0 - alpha)
                if na > 0.0:
                    cr = (rgb[0] * alpha + cr * ca * (1.0 - alpha)) / na
                    cg = (rgb[1] * alpha + cg * ca * (1.0 - alpha)) / na
                    cb = (rgb[2] * alpha + cb * ca * (1.0 - alpha)) / na
                ca = na

            i = (y * width + x) * 4
            da = rgba[i + 3] / 255.0
            out_a = ca + da * (1.0 - ca)
            if out_a <= 0.0:
                rgba[i:i + 4] = bytes((0, 0, 0, 0))
                continue
            rgba[i] = int(round((cr * ca + rgba[i] * da * (1.0 - ca)) / out_a))
            rgba[i + 1] = int(round((cg * ca + rgba[i + 1] * da * (1.0 - ca)) / out_a))
            rgba[i + 2] = int(round((cb * ca + rgba[i + 2] * da * (1.0 - ca)) / out_a))
            rgba[i + 3] = int(round(out_a * 255))


def self_check_icon(rgba, size):
    """⚠️ 一定要自检，否则会静默产出空白图"""
    colors = set()
    for i in range(0, len(rgba), 4):
        colors.add(bytes(rgba[i:i + 3]))
    if len(colors) < 50:
        raise SystemExit("自检失败：颜色数只有 %d，图标可能是空白" % len(colors))

    mid = (size // 2 * size + size // 2) * 4
    corner = (2 * size + 2) * 4
    if sum(rgba[mid:mid + 3]) >= sum(rgba[corner:corner + 3]):
        raise SystemExit("自检失败：中心没比边角暗，圆点没画上去")
    if rgba[mid + 3] != 255 or rgba[corner + 3] != 255:
        raise SystemExit("自检失败：给 App 用的图标不该有透明像素")
    return len(colors)


def self_check_dot(rgba, size, style_name):
    """球本体贴图：中间必须有东西，四角必须全透明，边缘必须有抗锯齿过渡"""
    # 圆点中心：身子 + 十字叠起来，alpha 大概 0.7 上下（不是 1.0，别按 1.0 卡）
    center_alpha = rgba[(size // 2 * size + size // 2) * 4 + 3]
    if center_alpha < 120:
        raise SystemExit("自检失败[%s]：贴图中心太透明（alpha=%d）" % (style_name, center_alpha))
    for cx, cy in ((0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1)):
        if rgba[(cy * size + cx) * 4 + 3] != 0:
            raise SystemExit("自检失败[%s]：贴图四角不是全透明" % style_name)
    # 抗锯齿的判据：得有相当数量的「半透明」像素（0 < alpha < 255）。
    # ⚠️ 别用「alpha 层次数」卡（不带十字的样式层次天然就少，会误报）。
    alphas = [rgba[i + 3] for i in range(3, len(rgba) - 3, 4)]
    partial = sum(1 for a in alphas if 0 < a < 255)
    if partial < 100:
        raise SystemExit("自检失败[%s]：半透明像素只有 %d 个，边缘没抗锯齿"
                         % (style_name, partial))
    return center_alpha, partial


def main():
    out = os.path.abspath(OUT_DIR)
    os.makedirs(out, exist_ok=True)

    # --- 1. 桌面图标（固定用默认样式）---
    for scale, name in ((2, "AppIcon60x60@2x.png"), (3, "AppIcon60x60@3x.png")):
        size = 60 * scale
        rgba = bytearray(size * size * 4)
        fill_gradient(rgba, size, size)
        d = size * ICON_DOT_RATIO
        draw_dot(rgba, size, size, size / 2.0, size / 2.0, d, STYLES[DEFAULT_STYLE])
        n = self_check_icon(rgba, size)
        path = os.path.join(out, name)
        write_png(path, size, size, rgba)
        print("%-22s %dx%d  %6d bytes  颜色数=%d" %
              (name, size, size, os.path.getsize(path), n))

    # --- 2. 球本体贴图（满幅，屏幕上按 pt 缩放显示）---
    size = 256
    for style_name in ("BallDot", "BallPlain", "BallWhite"):
        rgba = bytearray(size * size * 4)
        draw_dot(rgba, size, size, size / 2.0, size / 2.0, float(size), STYLES[style_name])
        center_alpha, partial = self_check_dot(rgba, size, style_name)
        path = os.path.join(out, style_name + ".png")
        write_png(path, size, size, rgba)
        print("%-22s %dx%d  %6d bytes  中心alpha=%d 半透明像素=%d" %
              (style_name + ".png", size, size, os.path.getsize(path), center_alpha, partial))


if __name__ == "__main__":
    main()
