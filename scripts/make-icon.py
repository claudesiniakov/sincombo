#!/usr/bin/env python3
"""Рисует иконку SinCombo (1024×1024 PNG): три сцепленные шестерёнки на тёмном скруглённом квадрате.

Запуск: python3 scripts/make-icon.py [путь/к/AppIcon.png]
"""
import math
import sys

from PIL import Image, ImageDraw

S = 4  # суперсэмплинг для сглаживания
N = 1024 * S


def gear(draw, cx, cy, outer, inner, teeth, hole, rotation, fill, bg_at):
    step = 2 * math.pi / teeth
    profile = [(-0.27, inner), (-0.14, outer), (0.14, outer), (0.27, inner)]
    points = []
    for tooth in range(teeth):
        for offset, radius in profile:
            a = rotation + (tooth + offset) * step
            points.append((cx + radius * math.cos(a), cy + radius * math.sin(a)))
    draw.polygon(points, fill=fill)
    draw.ellipse([cx - hole, cy - hole, cx + hole, cy + hole], fill=bg_at(cy))


def main(out):
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    pad = 100 * S
    top, bottom = (40, 52, 74), (14, 18, 30)

    def bg_at(y):
        t = min(1, max(0, y / (N - 1)))
        return tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,)

    bg = Image.new("RGBA", (N, N))
    bd = ImageDraw.Draw(bg)
    for y in range(N):
        bd.line([(0, y), (N, y)], fill=bg_at(y))
    mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(mask).rounded_rectangle([pad, pad, N - pad, N - pad], radius=185 * S, fill=255)
    img.paste(bg, (0, 0), mask)

    d = ImageDraw.Draw(img)
    white = (244, 246, 250, 255)
    # Сетка 24×24, как у значка в строке меню; вписана в поле 560 px по центру.
    k = 560 * S / 24
    ox = oy = (N - 560 * S) / 2
    for cx, cy, outer, inner, teeth, hole, rot in [
        (9, 14.5, 7.6, 5.7, 9, 2.3, 0),
        (17.6, 6.6, 4.9, 3.5, 7, 1.4, 0.2),
        (19.3, 17.6, 3.7, 2.6, 6, 1.0, 0.5),
    ]:
        gear(d, ox + cx * k, oy + cy * k, outer * k, inner * k, teeth, hole * k, rot, white, bg_at)

    img.resize((1024, 1024), Image.LANCZOS).save(out)
    print("Сохранено:", out)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "Resources/AppIcon.png")
