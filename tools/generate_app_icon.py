#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFilter


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ASSET_DIR = PROJECT_ROOT / "ReminderScreenSync" / "Assets.xcassets" / "AppIcon.appiconset"
OUTPUT_NAME = "AppIcon-master.png"
SIZE = 1024


def rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[index:index + 2], 16) for index in (0, 2, 4))


def mix(start: tuple[int, int, int], end: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a + (b - a) * t) for a, b in zip(start, end))


def add_glow(
    target: Image.Image,
    bbox: tuple[int, int, int, int],
    color: tuple[int, int, int, int],
    blur: int,
) -> None:
    glow = Image.new("RGBA", target.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow)
    draw.ellipse(bbox, fill=color)
    glow = glow.filter(ImageFilter.GaussianBlur(blur))
    target.alpha_composite(glow)


def draw_vertical_gradient(
    size: tuple[int, int],
    top: tuple[int, int, int],
    bottom: tuple[int, int, int],
) -> Image.Image:
    image = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    width, height = size
    for y in range(height):
        color = mix(top, bottom, y / max(height - 1, 1))
        draw.line((0, y, width, y), fill=color + (255,), width=1)
    return image


def rounded_rect_mask(size: tuple[int, int], bbox: tuple[int, int, int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(bbox, radius=radius, fill=255)
    return mask


def add_shadow(
    target: Image.Image,
    alpha_source: Image.Image,
    offset: tuple[int, int],
    blur: int,
    color: tuple[int, int, int, int],
    destination: tuple[int, int] = (0, 0),
) -> None:
    shadow = Image.new("RGBA", alpha_source.size, (0, 0, 0, 0))
    shadow.paste(color, mask=alpha_source)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    target.alpha_composite(
        shadow,
        dest=(destination[0] + offset[0], destination[1] + offset[1]),
    )


def draw_tick(
    draw: ImageDraw.ImageDraw,
    origin: tuple[int, int],
    size: int,
    color: tuple[int, int, int, int],
    width: int,
) -> None:
    x, y = origin
    points = [
        (x, y + size * 0.56),
        (x + size * 0.28, y + size * 0.82),
        (x + size, y),
    ]
    draw.line(points, fill=color, width=width, joint="curve")


def create_tile_background() -> Image.Image:
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    tile_bbox = (54, 54, SIZE - 54, SIZE - 54)
    tile_radius = 212

    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (70, 86, SIZE - 46, SIZE - 34),
        radius=tile_radius,
        fill=(4, 11, 24, 120),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(34))
    canvas.alpha_composite(shadow)

    gradient = draw_vertical_gradient((SIZE, SIZE), rgb("#0B2234"), rgb("#178799"))
    add_glow(gradient, (-60, -10, 430, 430), (255, 176, 76, 110), 90)
    add_glow(gradient, (600, 620, 1070, 1090), (122, 251, 255, 120), 110)

    accent = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    accent_draw = ImageDraw.Draw(accent)
    accent_draw.polygon(
        [(160, 160), (532, 80), (924, 300), (844, 408), (350, 302)],
        fill=(255, 255, 255, 24),
    )
    accent_draw.polygon(
        [(114, 760), (612, 652), (938, 810), (862, 914), (300, 942)],
        fill=(4, 21, 35, 42),
    )
    gradient.alpha_composite(accent)

    mask = rounded_rect_mask((SIZE, SIZE), tile_bbox, tile_radius)
    tile = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    tile.paste(gradient, mask=mask)

    overlay = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    overlay_draw = ImageDraw.Draw(overlay)
    overlay_draw.rounded_rectangle(
        tile_bbox,
        radius=tile_radius,
        outline=(255, 255, 255, 46),
        width=3,
    )
    overlay_draw.rounded_rectangle(
        (80, 80, SIZE - 80, SIZE - 80),
        radius=186,
        outline=(0, 0, 0, 30),
        width=2,
    )
    tile.alpha_composite(overlay)

    canvas.alpha_composite(tile)
    return canvas


def create_screen() -> Image.Image:
    width, height = 490, 420
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    draw.rounded_rectangle(
        (0, 0, width, height),
        radius=82,
        fill=(11, 19, 35, 255),
        outline=(255, 255, 255, 32),
        width=3,
    )
    draw.rounded_rectangle(
        (22, 22, width - 22, height - 22),
        radius=64,
        fill=(17, 46, 71, 255),
        outline=(106, 217, 222, 46),
        width=2,
    )

    draw.rounded_rectangle(
        (50, 58, width - 50, 106),
        radius=24,
        fill=(255, 255, 255, 26),
    )
    draw.ellipse((width - 106, 71, width - 84, 93), fill=(255, 183, 76, 255))
    draw.ellipse((width - 76, 71, width - 54, 93), fill=(114, 251, 255, 180))

    rows = [150, 218, 286]
    for index, row in enumerate(rows):
        bubble_fill = (255, 192, 92, 255) if index == 0 else (118, 240, 232, 235)
        draw.ellipse((68, row - 18, 104, row + 18), fill=bubble_fill)
        draw_tick(draw, (76, row - 8), 18, (12, 33, 49, 255), 6)
        draw.rounded_rectangle(
            (128, row - 10, width - 88, row + 8),
            radius=9,
            fill=(238, 248, 248, 220 if index == 0 else 178),
        )
        draw.rounded_rectangle(
            (128, row + 20, width - (164 if index == 1 else 208), row + 34),
            radius=7,
            fill=(186, 226, 231, 124),
        )

    draw.rounded_rectangle(
        (156, height - 84, width - 156, height - 60),
        radius=10,
        fill=(255, 255, 255, 28),
    )
    return image


def create_card() -> Image.Image:
    width, height = 380, 520
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    draw.rounded_rectangle(
        (0, 0, width, height),
        radius=50,
        fill=(248, 244, 234, 255),
        outline=(255, 255, 255, 120),
        width=3,
    )
    draw.rounded_rectangle(
        (0, 0, width, 88),
        radius=50,
        fill=(245, 164, 69, 255),
    )
    draw.rectangle((0, 44, width, 88), fill=(245, 164, 69, 255))

    draw.polygon(
        [(width - 82, 0), (width, 0), (width, 82)],
        fill=(255, 219, 167, 255),
    )
    draw.line((width - 82, 0, width - 2, 80), fill=(236, 196, 140, 255), width=3)

    draw.rounded_rectangle((42, 132, 122, 212), radius=28, fill=(29, 153, 167, 255))
    draw_tick(draw, (62, 154), 40, (247, 252, 250, 255), 10)
    draw.rounded_rectangle((146, 152, width - 48, 176), radius=12, fill=(39, 74, 92, 255))
    draw.rounded_rectangle((146, 192, width - 98, 210), radius=9, fill=(99, 128, 143, 180))

    row_y = 278
    for offset, line_width in zip((0, 84, 168), (width - 100, width - 134, width - 176)):
        y = row_y + offset
        draw.ellipse((56, y - 14, 84, y + 14), fill=(245, 164, 69, 255))
        draw_tick(draw, (62, y - 6), 14, (255, 248, 240, 255), 5)
        draw.rounded_rectangle((112, y - 8, line_width, y + 8), radius=8, fill=(66, 99, 118, 214))
        draw.rounded_rectangle((112, y + 18, line_width - 52, y + 30), radius=6, fill=(141, 160, 171, 135))

    return image


def arrowhead_points(
    tip: tuple[int, int],
    tail: tuple[int, int],
    length: int,
    width: int,
) -> Iterable[tuple[int, int]]:
    tx, ty = tip
    sx, sy = tail
    dx = tx - sx
    dy = ty - sy
    magnitude = max((dx * dx + dy * dy) ** 0.5, 1.0)
    ux = dx / magnitude
    uy = dy / magnitude
    px = -uy
    py = ux
    base_x = tx - ux * length
    base_y = ty - uy * length
    return (
        (round(tx), round(ty)),
        (round(base_x + px * width / 2), round(base_y + py * width / 2)),
        (round(base_x - px * width / 2), round(base_y - py * width / 2)),
    )


def draw_sync_arrows(target: Image.Image) -> None:
    shadow = Image.new("RGBA", target.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    top_points = [(232, 256), (430, 150), (668, 154), (818, 268)]
    bottom_points = [(784, 786), (560, 880), (336, 880), (190, 760)]

    shadow_draw.line(top_points, fill=(2, 8, 19, 85), width=54, joint="curve")
    shadow_draw.line(bottom_points, fill=(2, 8, 19, 85), width=54, joint="curve")
    shadow_draw.polygon(arrowhead_points(top_points[-1], top_points[-2], 44, 50), fill=(2, 8, 19, 85))
    shadow_draw.polygon(arrowhead_points(bottom_points[-1], bottom_points[-2], 44, 50), fill=(2, 8, 19, 85))
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    target.alpha_composite(shadow)

    arrows = Image.new("RGBA", target.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(arrows)
    draw.line(top_points, fill=(255, 190, 89, 255), width=40, joint="curve")
    draw.line(bottom_points, fill=(190, 255, 247, 240), width=40, joint="curve")
    draw.polygon(arrowhead_points(top_points[-1], top_points[-2], 60, 60), fill=(255, 190, 89, 255))
    draw.polygon(arrowhead_points(bottom_points[-1], bottom_points[-2], 60, 60), fill=(190, 255, 247, 240))
    target.alpha_composite(arrows)


def compose_icon() -> Image.Image:
    canvas = create_tile_background()
    draw_sync_arrows(canvas)

    screen = create_screen()
    add_shadow(canvas, screen.getchannel("A"), offset=(22, 24), blur=26, color=(0, 0, 0, 104), destination=(388, 318))
    canvas.alpha_composite(screen, dest=(388, 318))

    card = create_card().rotate(-8, resample=Image.Resampling.BICUBIC, expand=True)
    add_shadow(canvas, card.getchannel("A"), offset=(18, 24), blur=24, color=(0, 0, 0, 96), destination=(142, 238))
    canvas.alpha_composite(card, dest=(142, 238))

    foreground = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(foreground)
    draw.rounded_rectangle((130, 134, 894, 894), radius=180, outline=(255, 255, 255, 18), width=2)
    add_glow(foreground, (646, 124, 930, 350), (255, 255, 255, 56), 54)
    canvas.alpha_composite(foreground)

    return canvas


def main() -> None:
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    image = compose_icon()
    output_path = ASSET_DIR / OUTPUT_NAME
    image.save(output_path)
    print(output_path)


if __name__ == "__main__":
    main()
