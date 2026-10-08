#!/usr/bin/env python3
"""Generate Chostty's icon artwork.

Chostty uses original artwork instead of Ghostty's icon. The application icon
assets are produced by this script from one motif -- a window whose left sidebar holds
workspaces and whose main area holds a terminal prompt -- so the artwork can be
regenerated after a design change instead of edited by hand.

Requires Pillow (`python3 -m pip install pillow`). Run from the repository
root:

    python3 macos/scripts/generate-icons.py
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "macos" / "Assets.xcassets"
ICON_BUNDLE = ROOT / "images" / "Chostty.icon"

CANVAS = 1024
SS = 4  # supersampling factor for anti-aliased shapes

# macOS icon grid: an 824pt body centred on a 1024pt canvas.
BODY = (100, 100, 924, 924)
BODY_RADIUS = 185

Color = tuple[int, int, int, int]


def rgba(hex_value: str, alpha: int = 255) -> Color:
    hex_value = hex_value.lstrip("#")
    return (int(hex_value[0:2], 16), int(hex_value[2:4], 16), int(hex_value[4:6], 16), alpha)


# MARK: - Drawing primitives


def canvas() -> Image.Image:
    return Image.new("RGBA", (CANVAS * SS, CANVAS * SS), (0, 0, 0, 0))


def scaled(box: tuple[float, float, float, float]) -> tuple[int, int, int, int]:
    return tuple(int(round(v * SS)) for v in box)  # type: ignore[return-value]


def finish(image: Image.Image) -> Image.Image:
    return image.resize((CANVAS, CANVAS), Image.LANCZOS)


def mask_rounded(box, radius) -> Image.Image:
    mask = Image.new("L", (CANVAS * SS, CANVAS * SS), 0)
    ImageDraw.Draw(mask).rounded_rectangle(scaled(box), radius=radius * SS, fill=255)
    return mask


def gradient(top: Color, bottom: Color, angle_deg: float = 90) -> Image.Image:
    """A linear gradient across the full supersampled canvas."""
    size = CANVAS * SS
    small = 256
    image = Image.new("RGBA", (small, small))
    pixels = image.load()
    theta = math.radians(angle_deg)
    dx, dy = math.cos(theta), math.sin(theta)
    for y in range(small):
        for x in range(small):
            u = ((x / (small - 1) - 0.5) * dx + (y / (small - 1) - 0.5) * dy) + 0.5
            u = min(max(u, 0.0), 1.0)
            pixels[x, y] = tuple(int(round(a + (b - a) * u)) for a, b in zip(top, bottom))
    return image.resize((size, size), Image.BICUBIC)


def multi_gradient(stops: list[Color], angle_deg: float) -> Image.Image:
    size = CANVAS * SS
    small = 256
    image = Image.new("RGBA", (small, small))
    pixels = image.load()
    theta = math.radians(angle_deg)
    dx, dy = math.cos(theta), math.sin(theta)
    segments = len(stops) - 1
    for y in range(small):
        for x in range(small):
            u = ((x / (small - 1) - 0.5) * dx + (y / (small - 1) - 0.5) * dy) + 0.5
            u = min(max(u, 0.0), 1.0) * segments
            i = min(int(u), segments - 1)
            t = u - i
            a, b = stops[i], stops[i + 1]
            pixels[x, y] = tuple(int(round(p + (q - p) * t)) for p, q in zip(a, b))
    return image.resize((size, size), Image.BICUBIC)


def paste_fill(target: Image.Image, fill: Image.Image | Color, mask: Image.Image) -> None:
    if isinstance(fill, tuple):
        fill = Image.new("RGBA", target.size, fill)
    layer = Image.new("RGBA", target.size, (0, 0, 0, 0))
    layer.paste(fill, (0, 0), mask)
    target.alpha_composite(layer)


def shadow(mask: Image.Image, offset: int, blur: int, alpha: int) -> Image.Image:
    shifted = Image.new("L", mask.size, 0)
    shifted.paste(mask, (0, offset * SS))
    shifted = shifted.filter(ImageFilter.GaussianBlur(blur * SS))
    layer = Image.new("RGBA", mask.size, (0, 0, 0, 0))
    layer.putalpha(shifted.point(lambda a: a * alpha // 255))
    return layer


# MARK: - The motif


@dataclass(frozen=True)
class Geometry:
    """Where the window motif sits; shared by every variant and layer."""

    screen: tuple[float, float, float, float] = (186, 204, 838, 820)
    screen_radius: float = 64
    sidebar_width: float = 156
    pill_height: float = 44
    pill_gap: float = 28
    # The main area splits into a prompt pane and a narrower second pane.
    split_x: float = 702
    divider_width: float = 10


GEOMETRY = Geometry()


def sidebar_box(geo: Geometry = GEOMETRY):
    x0, y0, _, y1 = geo.screen
    return (x0, y0, x0 + geo.sidebar_width, y1)


def glyph_mask(geo: Geometry = GEOMETRY, include_sidebar: bool = True) -> Image.Image:
    """Workspace pills, the prompt chevron and the cursor, as one mask."""
    mask = Image.new("L", (CANVAS * SS, CANVAS * SS), 0)
    draw = ImageDraw.Draw(mask)
    x0, y0, x1, y1 = geo.screen

    if include_sidebar:
        px0 = x0 + 34
        px1 = x0 + geo.sidebar_width - 34
        top = y0 + 52
        for index in range(3):
            py0 = top + index * (geo.pill_height + geo.pill_gap)
            draw.rounded_rectangle(
                scaled((px0, py0, px1 if index == 0 else px1 - 22, py0 + geo.pill_height)),
                radius=geo.pill_height / 2 * SS,
                fill=255,
            )

    # Prompt chevron in the left pane.
    main_x0 = x0 + geo.sidebar_width
    cx = main_x0 + 74
    cy = (y0 + y1) / 2 + 10
    arm = 104
    stroke = 60
    points = [(cx, cy - arm), (cx + arm * 0.95, cy), (cx, cy + arm)]
    draw.line([(px * SS, py * SS) for px, py in points], fill=255, width=int(stroke * SS), joint="curve")
    for px, py in (points[0], points[2]):
        r = stroke / 2
        draw.ellipse(scaled((px - r, py - r, px + r, py + r)), fill=255)

    # Cursor block.
    cur_x0 = cx + arm * 0.95 + 56
    draw.rounded_rectangle(
        scaled((cur_x0, cy + arm - stroke, cur_x0 + 108, cy + arm)),
        radius=stroke / 2 * SS,
        fill=255,
    )
    return mask


def chevron_and_cursor_mask(geo: Geometry = GEOMETRY) -> Image.Image:
    return glyph_mask(geo, include_sidebar=False)


def second_pane_mask(geo: Geometry = GEOMETRY) -> Image.Image:
    """The split divider and the second pane's output lines."""
    mask = Image.new("L", (CANVAS * SS, CANVAS * SS), 0)
    draw = ImageDraw.Draw(mask)
    _, y0, x1, y1 = geo.screen
    half = geo.divider_width / 2
    draw.rectangle(scaled((geo.split_x - half, y0, geo.split_x + half, y1)), fill=255)
    line_x0 = geo.split_x + 36
    for index, width in enumerate((76, 52, 66, 40)):
        ly = y0 + 64 + index * 58
        draw.rounded_rectangle(scaled((line_x0, ly, line_x0 + width, ly + 22)), radius=11 * SS, fill=255)
    return ImageChops.multiply(mask, mask_rounded(geo.screen, geo.screen_radius))


def pills_mask(geo: Geometry = GEOMETRY) -> Image.Image:
    return ImageChops.subtract(glyph_mask(geo), chevron_and_cursor_mask(geo))


def first_pill_mask(geo: Geometry = GEOMETRY) -> Image.Image:
    mask = Image.new("L", (CANVAS * SS, CANVAS * SS), 0)
    x0, y0, _, _ = geo.screen
    top = y0 + 52
    ImageDraw.Draw(mask).rounded_rectangle(
        scaled((x0 + 34, top, x0 + geo.sidebar_width - 34, top + geo.pill_height)),
        radius=geo.pill_height / 2 * SS,
        fill=255,
    )
    return mask


# MARK: - Themes


@dataclass(frozen=True)
class Theme:
    body: list[Color]
    body_angle: float
    screen: list[Color]
    sidebar: Color
    pills: Color
    active_pill: Color
    prompt: list[Color]
    rim: Color = (255, 255, 255, 70)
    overlay: str | None = None
    glow: Color | None = None

    @property
    def panes(self) -> Color:
        """Divider and second-pane lines: the pill color, quieter."""
        r, g, b, a = self.pills
        return (r, g, b, a * 45 // 100)


OFFICIAL = Theme(
    body=[rgba("#4B2C8F"), rgba("#1B1442")],
    body_angle=90,
    screen=[rgba("#120D2A"), rgba("#0A0718")],
    sidebar=rgba("#FFFFFF", 24),
    pills=rgba("#FFFFFF", 115),
    active_pill=rgba("#FFC27A"),
    prompt=[rgba("#FFD27A"), rgba("#FF4F8B")],
)

THEMES: dict[str, Theme] = {
    "BlueprintImage": Theme(
        body=[rgba("#2F6FD6"), rgba("#1C4BA0")],
        body_angle=90,
        screen=[rgba("#2459B8"), rgba("#1D4C9E")],
        sidebar=rgba("#FFFFFF", 30),
        pills=rgba("#FFFFFF", 150),
        active_pill=rgba("#FFFFFF"),
        prompt=[rgba("#FFFFFF"), rgba("#DDE9FF")],
        overlay="grid",
    ),
    "ChalkboardImage": Theme(
        body=[rgba("#7A5A3A"), rgba("#4E3722")],
        body_angle=90,
        screen=[rgba("#2F4A3A"), rgba("#243A2D")],
        sidebar=rgba("#FFFFFF", 18),
        pills=rgba("#E9EFE6", 130),
        active_pill=rgba("#F4E9A6"),
        prompt=[rgba("#F2F2EA"), rgba("#D9DED2")],
        overlay="chalk",
    ),
    "MicrochipImage": Theme(
        body=[rgba("#1E6B45"), rgba("#0F3F27")],
        body_angle=90,
        screen=[rgba("#123526"), rgba("#0B2419")],
        sidebar=rgba("#E2B04A", 30),
        pills=rgba("#E2B04A", 150),
        active_pill=rgba("#F3CF6B"),
        prompt=[rgba("#F3CF6B"), rgba("#C98F25")],
        overlay="traces",
    ),
    "GlassImage": Theme(
        body=[rgba("#DDEBFF", 235), rgba("#A9C6EE", 235)],
        body_angle=90,
        screen=[rgba("#FFFFFF", 120), rgba("#E6F0FF", 90)],
        sidebar=rgba("#FFFFFF", 90),
        pills=rgba("#5B7DB1", 120),
        active_pill=rgba("#3E67A8"),
        prompt=[rgba("#3E67A8"), rgba("#2B4C85")],
        rim=rgba("#FFFFFF", 160),
    ),
    "HolographicImage": Theme(
        body=[rgba("#F7B2D9"), rgba("#B9A7F5"), rgba("#9BE3F0"), rgba("#C8F5B8")],
        body_angle=45,
        screen=[rgba("#1B1630"), rgba("#120F22")],
        sidebar=rgba("#FFFFFF", 28),
        pills=rgba("#FFFFFF", 120),
        active_pill=rgba("#9BE3F0"),
        prompt=[rgba("#F7B2D9"), rgba("#9BE3F0")],
    ),
    "PaperImage": Theme(
        body=[rgba("#F6F1E6"), rgba("#E3DBC9")],
        body_angle=90,
        screen=[rgba("#FFFDF8"), rgba("#F7F2E7")],
        sidebar=rgba("#2A2622", 18),
        pills=rgba("#2A2622", 110),
        active_pill=rgba("#2A2622"),
        prompt=[rgba("#2A2622"), rgba("#2A2622")],
        rim=rgba("#FFFFFF", 120),
    ),
    "RetroImage": Theme(
        body=[rgba("#E7DCC3"), rgba("#C9BB98")],
        body_angle=90,
        screen=[rgba("#1E1A12"), rgba("#14110B")],
        sidebar=rgba("#FFB000", 22),
        pills=rgba("#FFB000", 120),
        active_pill=rgba("#FFB000"),
        prompt=[rgba("#FFC23D"), rgba("#FF9A00")],
        overlay="scanlines",
        glow=rgba("#FFB000", 150),
    ),
    "XrayImage": Theme(
        body=[rgba("#1A1D22"), rgba("#0A0B0D")],
        body_angle=90,
        screen=[rgba("#05070A"), rgba("#020304")],
        sidebar=rgba("#5FF2FF", 18),
        pills=rgba("#5FF2FF", 120),
        active_pill=rgba("#9FF8FF"),
        prompt=[rgba("#D9FDFF"), rgba("#5FF2FF")],
        glow=rgba("#5FF2FF", 190),
        rim=rgba("#5FF2FF", 90),
    ),
}


def overlay_pattern(kind: str, clip: Image.Image) -> Image.Image:
    layer = Image.new("RGBA", clip.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    size = CANVAS * SS
    if kind == "grid":
        for step, alpha in ((32, 28), (128, 55)):
            for v in range(0, size, step * SS):
                draw.line([(v, 0), (v, size)], fill=(255, 255, 255, alpha), width=SS)
                draw.line([(0, v), (size, v)], fill=(255, 255, 255, alpha), width=SS)
    elif kind == "scanlines":
        for v in range(0, size, 8 * SS):
            draw.rectangle([0, v, size, v + 3 * SS], fill=(0, 0, 0, 70))
    elif kind == "chalk":
        rng = random.Random(7)
        for _ in range(2600):
            x, y = rng.randrange(size), rng.randrange(size)
            r = rng.randrange(1, 4) * SS
            draw.ellipse([x, y, x + r, y + r], fill=(255, 255, 255, rng.randrange(8, 26)))
    elif kind == "traces":
        rng = random.Random(11)
        for _ in range(22):
            x = rng.randrange(120, 900) * SS
            y = rng.randrange(120, 900) * SS
            length = rng.randrange(60, 220) * SS
            horizontal = rng.random() < 0.5
            end = (x + length, y) if horizontal else (x, y + length)
            draw.line([(x, y), end], fill=(226, 176, 74, 45), width=6 * SS)
            draw.ellipse([end[0] - 9 * SS, end[1] - 9 * SS, end[0] + 9 * SS, end[1] + 9 * SS],
                         fill=(226, 176, 74, 60))
    alpha = ImageChops.multiply(layer.getchannel("A"), clip)
    layer.putalpha(alpha)
    return layer


def render_icon(theme: Theme) -> Image.Image:
    """A complete pre-Tahoe icon: body, screen, sidebar and prompt."""
    image = canvas()
    body = mask_rounded(BODY, BODY_RADIUS)
    image.alpha_composite(shadow(body, offset=10, blur=14, alpha=110))

    body_fill = (multi_gradient(theme.body, theme.body_angle) if len(theme.body) > 2
                 else gradient(theme.body[0], theme.body[1], theme.body_angle))
    paste_fill(image, body_fill, body)
    if theme.overlay in ("grid", "chalk", "traces"):
        image.alpha_composite(overlay_pattern(theme.overlay, body))

    # Rim light along the body's top edge.
    inner = mask_rounded((BODY[0] + 4, BODY[1] + 4, BODY[2] - 4, BODY[3] - 4), BODY_RADIUS - 4)
    rim = ImageChops.subtract(body, inner)
    rim_fade = gradient((255, 255, 255, 255), (255, 255, 255, 0), 90).getchannel("A")
    paste_fill(image, theme.rim, ImageChops.multiply(rim, rim_fade))

    screen = mask_rounded(GEOMETRY.screen, GEOMETRY.screen_radius)
    image.alpha_composite(shadow(screen, offset=6, blur=10, alpha=90))
    paste_fill(image, gradient(theme.screen[0], theme.screen[1], 90), screen)
    if theme.overlay == "scanlines":
        image.alpha_composite(overlay_pattern("scanlines", screen))

    sidebar = ImageChops.multiply(screen, mask_rounded(sidebar_box(), 0))
    paste_fill(image, theme.sidebar, sidebar)
    paste_fill(image, theme.panes, second_pane_mask())

    glyph = chevron_and_cursor_mask()
    if theme.glow:
        glow = glyph.filter(ImageFilter.GaussianBlur(18 * SS))
        paste_fill(image, theme.glow, glow)
    paste_fill(image, theme.pills, ImageChops.subtract(pills_mask(), first_pill_mask()))
    paste_fill(image, theme.active_pill, first_pill_mask())
    paste_fill(image, gradient(theme.prompt[0], theme.prompt[1], 60), glyph)
    return finish(image)


# MARK: - Custom-style layers
#
# `ColorizedGhosttyIcon` composites these in order: base, screen,
# screen-mask gradient (color blend), glyph, tinted glyph (color blend),
# effect (overlay), gloss. The glyph is a light-gray template.

FRAMES: dict[str, list[Color]] = {
    "CustomIconBaseAluminum": [rgba("#E9EBEE"), rgba("#9DA2AA")],
    "CustomIconBaseBeige": [rgba("#EFE6CF"), rgba("#C7B892")],
    "CustomIconBaseChrome": [rgba("#FAFBFC"), rgba("#6E747C")],
    "CustomIconBasePlastic": [rgba("#F4F4F2"), rgba("#C9CBCC")],
}


def render_frame(colors: list[Color]) -> Image.Image:
    image = canvas()
    body = mask_rounded(BODY, BODY_RADIUS)
    image.alpha_composite(shadow(body, offset=10, blur=14, alpha=110))
    paste_fill(image, gradient(colors[0], colors[1], 90), body)
    inner = mask_rounded((BODY[0] + 6, BODY[1] + 6, BODY[2] - 6, BODY[3] - 6), BODY_RADIUS - 6)
    paste_fill(image, (255, 255, 255, 90), ImageChops.subtract(body, inner))
    screen = mask_rounded(GEOMETRY.screen, GEOMETRY.screen_radius)
    image.alpha_composite(shadow(screen, offset=-4, blur=8, alpha=120))
    return finish(image)


def render_screen() -> Image.Image:
    image = canvas()
    screen = mask_rounded(GEOMETRY.screen, GEOMETRY.screen_radius)
    paste_fill(image, gradient(rgba("#1C1D24"), rgba("#0E0F14"), 90), screen)
    sidebar = ImageChops.multiply(screen, mask_rounded(sidebar_box(), 0))
    paste_fill(image, (255, 255, 255, 22), sidebar)
    paste_fill(image, (255, 255, 255, 40), second_pane_mask())
    return finish(image)


def render_screen_mask() -> Image.Image:
    image = canvas()
    paste_fill(image, (255, 255, 255, 255), mask_rounded(GEOMETRY.screen, GEOMETRY.screen_radius))
    return finish(image)


def render_glyph_template() -> Image.Image:
    image = canvas()
    paste_fill(image, (226, 226, 226, 255), glyph_mask())
    return finish(image)


def render_effect() -> Image.Image:
    image = canvas()
    screen = mask_rounded(GEOMETRY.screen, GEOMETRY.screen_radius)
    vignette = Image.new("L", screen.size, 0)
    x0, y0, x1, y1 = scaled(GEOMETRY.screen)
    ImageDraw.Draw(vignette).rounded_rectangle(
        (x0 + 60 * SS, y0 + 60 * SS, x1 - 60 * SS, y1 - 60 * SS), radius=40 * SS, fill=255)
    vignette = vignette.filter(ImageFilter.GaussianBlur(60 * SS))
    edge = ImageChops.multiply(screen, ImageChops.invert(vignette))
    paste_fill(image, (0, 0, 0, 120), edge)
    paste_fill(image, (255, 255, 255, 40), ImageChops.multiply(screen, vignette))
    return finish(image)


def render_gloss() -> Image.Image:
    image = canvas()
    x0, y0, x1, y1 = GEOMETRY.screen
    top = mask_rounded((x0 + 14, y0 + 14, x1 - 14, y0 + (y1 - y0) * 0.42), GEOMETRY.screen_radius - 14)
    fade = gradient((255, 255, 255, 70), (255, 255, 255, 0), 90)
    paste_fill(image, fade, top)
    return finish(image)


# MARK: - Icon Composer bundle (macOS 26+)


def render_composer_screen() -> Image.Image:
    image = canvas()
    screen = mask_rounded(GEOMETRY.screen, GEOMETRY.screen_radius)
    paste_fill(image, gradient(OFFICIAL.screen[0], OFFICIAL.screen[1], 90), screen)
    paste_fill(image, OFFICIAL.sidebar, ImageChops.multiply(screen, mask_rounded(sidebar_box(), 0)))
    paste_fill(image, OFFICIAL.panes, second_pane_mask())
    return finish(image)


def render_composer_glyph() -> Image.Image:
    image = canvas()
    paste_fill(image, OFFICIAL.pills, ImageChops.subtract(pills_mask(), first_pill_mask()))
    paste_fill(image, OFFICIAL.active_pill, first_pill_mask())
    paste_fill(image, gradient(OFFICIAL.prompt[0], OFFICIAL.prompt[1], 60), chevron_and_cursor_mask())
    return finish(image)


COMPOSER_JSON = """{
  "fill" : {
    "linear-gradient" : [
      "srgb:0.29412,0.17255,0.56078,1.00000",
      "srgb:0.10588,0.07843,0.25882,1.00000"
    ]
  },
  "groups" : [
    {
      "layers" : [
        {
          "glass" : false,
          "image-name" : "Prompt.png",
          "name" : "Prompt",
          "position" : {
            "scale" : 1.25,
            "translation-in-points" : [
              0,
              0
            ]
          }
        }
      ],
      "lighting" : "individual",
      "name" : "Prompt",
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0.5
      }
    },
    {
      "layers" : [
        {
          "glass" : true,
          "image-name" : "Screen.png",
          "name" : "Screen",
          "position" : {
            "scale" : 1.25,
            "translation-in-points" : [
              0,
              0
            ]
          }
        }
      ],
      "lighting" : "individual",
      "name" : "Screen",
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0.5
      }
    }
  ],
  "supported-platforms" : {
    "circles" : [
      "watchOS"
    ],
    "squares" : "shared"
  }
}
"""


def write(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)
    print(f"wrote {path.relative_to(ROOT)}")


def main() -> None:
    official = render_icon(OFFICIAL)
    app_icon = ASSETS / "AppIconImage.imageset"
    write(official, app_icon / "macOS-AppIcon-1024px.png")
    write(official.resize((512, 512), Image.LANCZOS), app_icon / "macOS-AppIcon-512px.png")
    write(official.resize((256, 256), Image.LANCZOS), app_icon / "macOS-AppIcon-256px-128pt@2x.png")

    for name, theme in THEMES.items():
        write(render_icon(theme), ASSETS / "Alternate Icons" / f"{name}.imageset" / "macOS-AppIcon-1024px.png")

    custom = ASSETS / "Custom Icon"
    for name, colors in FRAMES.items():
        file_name = {
            "CustomIconBaseAluminum": "base.png",
            "CustomIconBaseBeige": "beige.png",
            "CustomIconBaseChrome": "chrome.png",
            "CustomIconBasePlastic": "plastic.png",
        }[name]
        write(render_frame(colors), custom / f"{name}.imageset" / file_name)
    write(render_screen(), custom / "CustomIconScreen.imageset" / "screen-dark.png")
    write(render_screen_mask(), custom / "CustomIconScreenMask.imageset" / "screen-mask.png")
    write(render_glyph_template(), custom / "CustomIconGhost.imageset" / "ghosty.png")
    write(render_effect(), custom / "CustomIconCRT.imageset" / "crt-effect.png")
    write(render_gloss(), custom / "CustomIconGloss.imageset" / "gloss.png")

    write(render_composer_screen(), ICON_BUNDLE / "Assets" / "Screen.png")
    write(render_composer_glyph(), ICON_BUNDLE / "Assets" / "Prompt.png")
    (ICON_BUNDLE / "icon.json").write_text(COMPOSER_JSON)
    print(f"wrote {(ICON_BUNDLE / 'icon.json').relative_to(ROOT)}")

    images = ROOT / "images"
    # Linux packaging carries a nightly variant; it uses the Xray artwork.
    nightly = render_icon(THEMES["XrayImage"])
    for size in (16, 32, 64, 128, 256, 512, 1024, 2048):
        write(official.resize((size, size), Image.LANCZOS), images / "gnome" / f"{size}.png")
        write(nightly.resize((size, size), Image.LANCZOS), images / "gnome" / f"nightly-{size}.png")
    for size in (16, 32, 128, 256, 512, 1024):
        write(official.resize((size, size), Image.LANCZOS), images / "icons" / f"icon_{size}.png")
        write(official.resize((size * 2, size * 2), Image.LANCZOS), images / "icons" / f"icon_{size}@2x.png")

    dist = ROOT / "dist"
    write(official.resize((32, 32), Image.LANCZOS), dist / "doxygen" / "favicon.png")
    ico = dist / "windows" / "ghostty.ico"
    official.resize((256, 256), Image.LANCZOS).save(
        ico, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (256, 256)])
    print(f"wrote {ico.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
