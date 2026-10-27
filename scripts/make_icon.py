#!/usr/bin/env python3
"""Generate the cTerm app icon (requires Pillow)."""
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import math
import os

SIZE = 1024
# Apple's macOS icon grid: an 824pt body centred on the 1024 canvas. macOS 26
# only accepts a legacy icon whose body matches its continuous-corner squircle;
# anything else (even a plain rounded rect) is shrunk onto a white plate.
MARGIN = 100
font_path = "/System/Library/Fonts/SFNSMono.ttf"
font = ImageFont.truetype(font_path, 520)

# Vertical gradient background.
bg = Image.new("RGB", (SIZE, SIZE), "#070A10")
gradient = ImageDraw.Draw(bg)
top = (28, 44, 68)
bottom = (6, 9, 14)
for y in range(SIZE):
    t = y / (SIZE - 1)
    color = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
    gradient.line([(0, y), (SIZE, y)], fill=color)

# Soft blue glow in the upper right.
glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
gd.ellipse((520, -180, 1150, 520), fill=(76, 154, 255, 110))
glow = glow.filter(ImageFilter.GaussianBlur(120))
bg = Image.alpha_composite(bg.convert("RGBA"), glow)



def squircle_mask(margin, exponent=5.0, supersample=4):
    """A superellipse close to Apple's continuous-corner icon shape. No rim is
    drawn on it: macOS 26 adds its own edge highlight."""
    big = SIZE * supersample
    radius = (SIZE / 2 - margin) * supersample
    center = big / 2
    points = []
    for i in range(2000):
        t = 2 * math.pi * i / 2000
        c, s = math.cos(t), math.sin(t)
        points.append((
            center + radius * math.copysign(abs(c) ** (2 / exponent), c),
            center + radius * math.copysign(abs(s) ** (2 / exponent), s),
        ))
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask.resize((SIZE, SIZE), Image.LANCZOS)


mask = squircle_mask(MARGIN)

icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
icon.paste(bg, (0, 0), mask)

# Faint dot grid, like a terminal raster.
dot_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
dd = ImageDraw.Draw(dot_layer)
for y in range(150, 900, 64):
    for x in range(150, 900, 64):
        dd.ellipse((x, y, x + 3, y + 3), fill=(140, 170, 220, 18))
dot_layer = dot_layer.filter(ImageFilter.GaussianBlur(0.5))
dot_layer.putalpha(Image.composite(dot_layer.getchannel("A"), Image.new("L", (SIZE, SIZE), 0), mask))
icon = Image.alpha_composite(icon, dot_layer)

# Prompt: a blue chevron followed by a green block cursor.
text_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
td = ImageDraw.Draw(text_layer)
chevron_bbox = td.textbbox((0, 0), ">", font=font)
chevron_width = chevron_bbox[2] - chevron_bbox[0]
chevron_height = chevron_bbox[3] - chevron_bbox[1]
cursor_width = 160
cursor_height = 230
gap = 38
total_width = chevron_width + gap + cursor_width
start_x = (SIZE - total_width) / 2
center_y = 500
text_y = center_y - chevron_height / 2 - chevron_bbox[1]
td.text((start_x, text_y), ">", font=font, fill=(108, 182, 255, 255))
cursor_x = start_x + chevron_width + gap
cursor_y = center_y - cursor_height / 2
td.rounded_rectangle(
    (cursor_x, cursor_y, cursor_x + cursor_width, cursor_y + cursor_height),
    26,
    fill=(126, 231, 135, 235),
)

# Soft glow behind the prompt.
glow_text = text_layer.filter(ImageFilter.GaussianBlur(34))
icon = Image.alpha_composite(icon, glow_text)
icon = Image.alpha_composite(icon, text_layer)

icon.save("Resources/icon-1024.png")
print("wrote Resources/icon-1024.png")

sizes = [16, 32, 64, 128, 256, 512, 1024]
os.makedirs("Resources/cTerm.iconset", exist_ok=True)
for s in sizes:
    img = icon.resize((s, s), Image.LANCZOS)
    img.save(f"Resources/cTerm.iconset/icon_{s}x{s}.png")
    if s <= 512:
        img2 = icon.resize((s * 2, s * 2), Image.LANCZOS)
        img2.save(f"Resources/cTerm.iconset/icon_{s}x{s}@2x.png")
print("wrote iconset")
