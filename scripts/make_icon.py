#!/usr/bin/env python3
"""Generate the NotifyBridge app icon without external design assets."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

S = 1024
OUT = Path(__file__).resolve().parent.parent / "assets"
OUT.mkdir(parents=True, exist_ok=True)

# Vertical gradient: indigo -> cyan.
gradient = Image.new("RGB", (S, S))
top = (37, 78, 214)
bottom = (8, 145, 178)
for y in range(S):
    t = y / (S - 1)
    # Smoothstep for a softer transition.
    t = t * t * (3 - 2 * t)
    color = tuple(round(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
    ImageDraw.Draw(gradient).line((0, y, S, y), fill=color)

# Rounded square mask with a comfortable macOS-style margin.
margin = 74
radius = 218
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle(
    (margin, margin, S - margin, S - margin), radius=radius, fill=255
)

icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle(
    (margin + 4, margin + 20, S - margin + 4, S - margin + 20),
    radius=radius,
    fill=(8, 20, 55, 90),
)
shadow = shadow.filter(ImageFilter.GaussianBlur(22))
icon = Image.alpha_composite(icon, shadow)
icon.paste(gradient, (0, 0), mask)

draw = ImageDraw.Draw(icon)

# A white notification bubble with a small tail.
bubble = (224, 290, 770, 690)
bubble_shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
bs = ImageDraw.Draw(bubble_shadow)
bs.rounded_rectangle(
    (bubble[0] + 6, bubble[1] + 18, bubble[2] + 6, bubble[3] + 18),
    radius=92,
    fill=(8, 28, 62, 70),
)
bs.polygon([(330, 650), (300, 760), (430, 680)], fill=(8, 28, 62, 70))
bubble_shadow = bubble_shadow.filter(ImageFilter.GaussianBlur(20))
icon = Image.alpha_composite(icon, bubble_shadow)
draw = ImageDraw.Draw(icon)

draw.rounded_rectangle(bubble, radius=92, fill=(255, 255, 255, 255))
draw.polygon([(340, 660), (310, 770), (445, 690)], fill=(255, 255, 255, 255))

# Colored message lines inside the bubble.
line_color = (37, 99, 235)
draw.rounded_rectangle((312, 385, 608, 431), radius=23, fill=line_color)
draw.rounded_rectangle((312, 476, 680, 522), radius=23, fill=(147, 197, 253))
draw.rounded_rectangle((312, 567, 548, 613), radius=23, fill=(191, 219, 254))

# The small unread badge at the top-right, with a tiny bell.
badge_center = (766, 300)
badge_r = 112
draw.ellipse(
    (badge_center[0] - badge_r - 7, badge_center[1] - badge_r - 7,
     badge_center[0] + badge_r + 7, badge_center[1] + badge_r + 7),
    fill=(255, 255, 255, 255),
)
draw.ellipse(
    (badge_center[0] - badge_r, badge_center[1] - badge_r,
     badge_center[0] + badge_r, badge_center[1] + badge_r),
    fill=(249, 115, 22, 255),
)

# Bell: dome + body + clapper.
bx, by = badge_center
draw.rounded_rectangle((bx - 42, by - 36, bx + 42, by + 36), radius=30, fill=(255, 255, 255, 255))
draw.rectangle((bx - 42, by + 12, bx + 42, by + 40), fill=(255, 255, 255, 255))
draw.rectangle((bx - 54, by + 34, bx + 54, by + 50), fill=(255, 255, 255, 255))
draw.ellipse((bx - 15, by + 48, bx + 15, by + 78), fill=(255, 255, 255, 255))
# Cut the bottom edge of the dome to shape the bell.
draw.rectangle((bx - 32, by + 45, bx + 32, by + 60), fill=(249, 115, 22, 255))

# Draw two tiny Bluetooth-inspired waves at the bottom-left of the bubble tail.
# (Subtle enough to remain legible at 16 px.)

full = icon
full.save(OUT / "AppIcon-1024.png")

iconset = OUT / "AppIcon.iconset"
iconset.mkdir(parents=True, exist_ok=True)
for size in (16, 32, 64, 128, 256, 512, 1024):
    resized = full.resize((size, size), Image.Resampling.LANCZOS)
    if size in (32, 128, 256, 512):
        resized.save(iconset / f"icon_{size//2}x{size//2}@2x.png")
    if size in (16, 32, 128, 256, 512):
        resized.save(iconset / f"icon_{size}x{size}.png")

# The 1024 entry is also the 512@2x; keep a canonical copy.
full.resize((1024, 1024), Image.Resampling.LANCZOS).save(iconset / "icon_512x512@2x.png")
print("wrote", OUT / "AppIcon-1024.png")
print("wrote", iconset)
