#!/usr/bin/env python3
"""
Generate the Wattly Official macOS App Iconset.
Faithfully renders the exact dark matte squircle with soft ambient cyan-teal glow
and warm ivory/white calligraphic W matching the user's selected design.
Supersampled at 2048x2048 and downsampled to all 10 required AppIcon sizes.
"""

import os
from PIL import Image, ImageDraw, ImageFilter

def cubic_bezier(p0, p1, p2, p3, n_points=120):
    """Generate n_points along a cubic bezier curve."""
    points = []
    for i in range(n_points):
        t = i / (n_points - 1)
        x = (1-t)**3 * p0[0] + 3*(1-t)**2 * t * p1[0] + 3*(1-t) * t**2 * p2[0] + t**3 * p3[0]
        y = (1-t)**3 * p0[1] + 3*(1-t)**2 * t * p1[1] + 3*(1-t) * t**2 * p2[1] + t**3 * p3[1]
        points.append((x, y))
    return points

def generate_w_points(scale=1.0, offset=(0, 0)):
    """Generate sample points along the smooth calligraphic W curve matching the user's reference."""
    s = scale
    ox, oy = offset

    def pt(x, y):
        return (x * s + ox, y * s + oy)

    # 4 cubic bezier segments forming the exact W from the user's screenshot
    # Left tip (130, 255) -> Bottom Left (210, 355) -> Center Peak (256, 175) -> Bottom Right (302, 355) -> Right Tip (375, 235)
    seg1 = cubic_bezier(pt(130, 255), pt(158, 340), pt(182, 355), pt(210, 355), 70)
    seg2 = cubic_bezier(pt(210, 355), pt(234, 355), pt(242, 175), pt(256, 175), 70)
    seg3 = cubic_bezier(pt(256, 175), pt(270, 175), pt(278, 355), pt(302, 355), 70)
    seg4 = cubic_bezier(pt(302, 355), pt(330, 355), pt(354, 340), pt(375, 235), 70)

    return seg1 + seg2[1:] + seg3[1:] + seg4[1:]

def draw_squircle_mask(size, inset, radius):
    """Generate a smooth anti-aliased squircle mask."""
    mask = Image.new('L', (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        [inset, inset, size - inset, size - inset],
        radius=radius,
        fill=255
    )
    return mask

def generate_wattly_master(size=2048):
    """Renders the master icon at supersampled resolution (2048x2048)."""
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    
    # 1. macOS Squircle Geometry (Apple standard inset and continuous corner radius)
    inset = int(size * (32 / 512))  # 128px at 2048
    squircle_size = size - 2 * inset
    corner_radius = int(squircle_size * 0.2237)

    # 2. Multi-tier Drop Shadow (rendered behind squircle)
    shadow_layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    s_draw = ImageDraw.Draw(shadow_layer)
    s_draw.rounded_rectangle(
        [inset, inset + 48, size - inset, size - inset + 48],
        radius=corner_radius,
        fill=(0, 0, 0, 130)
    )
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(radius=56))
    
    near_shadow = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ns_draw = ImageDraw.Draw(near_shadow)
    ns_draw.rounded_rectangle(
        [inset, inset + 16, size - inset, size - inset + 16],
        radius=corner_radius,
        fill=(0, 0, 0, 90)
    )
    near_shadow = near_shadow.filter(ImageFilter.GaussianBlur(radius=22))
    
    canvas = Image.alpha_composite(canvas, shadow_layer)
    canvas = Image.alpha_composite(canvas, near_shadow)

    # 3. Dark Matte Obsidian Background Plate
    # Refined dark gradient: Top (#1C202B) -> Mid (#13161F) -> Bottom (#0C0E14)
    top_color = (28, 32, 43)
    mid_color = (19, 22, 31)
    bot_color = (12, 14, 20)
    
    gradient = Image.new('RGB', (1, size))
    for y in range(size):
        t = y / size
        if t < 0.5:
            r = int(top_color[0] * (1 - 2*t) + mid_color[0] * (2*t))
            g = int(top_color[1] * (1 - 2*t) + mid_color[1] * (2*t))
            b = int(top_color[2] * (1 - 2*t) + mid_color[2] * (2*t))
        else:
            t2 = (t - 0.5) * 2
            r = int(mid_color[0] * (1 - t2) + bot_color[0] * t2)
            g = int(mid_color[1] * (1 - t2) + bot_color[1] * t2)
            b = int(mid_color[2] * (1 - t2) + bot_color[2] * t2)
        gradient.putpixel((0, y), (r, g, b))
    
    bg_plate = gradient.resize((size, size), Image.Resampling.BICUBIC).convert('RGBA')

    # 4. Soft Ambient Glow (Cyan & Teal bloom spreading softly behind W)
    glow_layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    g_draw = ImageDraw.Draw(glow_layer)
    # Cyan bloom at top-right (x=1300, y=900)
    g_draw.ellipse([int(size*0.40), int(size*0.24), int(size*0.84), int(size*0.68)], fill=(56, 189, 248, 60))
    # Teal/Mint bloom at bottom-left (x=800, y=1200)
    g_draw.ellipse([int(size*0.22), int(size*0.38), int(size*0.68), int(size*0.82)], fill=(45, 212, 191, 55))
    glow_layer = glow_layer.filter(ImageFilter.GaussianBlur(radius=int(size * 0.085)))
    bg_plate = Image.alpha_composite(bg_plate, glow_layer)

    # 5. Tactile Warm White / Ivory Calligraphic W (The Exact Stroke)
    w_scale = size / 512.0
    w_points = generate_w_points(scale=w_scale)
    
    w_layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    w_draw = ImageDraw.Draw(w_layer)
    
    # (a) Deep ambient drop shadow under the W stroke (offset dx=4, dy=12, color=#040508)
    shadow_pts = [(x + 4 * w_scale, y + 12 * w_scale) for x, y in w_points]
    w_draw.line(shadow_pts, fill=(2, 3, 6, 180), width=int(80 * w_scale), joint='curve')
    w_layer = w_layer.filter(ImageFilter.GaussianBlur(radius=int(6.5 * w_scale)))
    
    # (b) Soft Ivory-Cream Body (#FBF9F4) with subtle warm edge
    w_draw_core = ImageDraw.Draw(w_layer)
    w_draw_core.line(w_points, fill=(225, 222, 212, 255), width=int(74 * w_scale), joint='curve')
    w_draw_core.line(w_points, fill=(251, 249, 244, 255), width=int(64 * w_scale), joint='curve')
    
    # (c) Pure White Specular Core Centerline (#FFFFFF)
    w_draw_core.line(w_points, fill=(255, 255, 255, 255), width=int(26 * w_scale), joint='curve')
    
    bg_plate = Image.alpha_composite(bg_plate, w_layer)

    # 6. Apply Squircle Mask to Base Plate
    mask = draw_squircle_mask(size, inset, corner_radius)
    bg_plate.putalpha(mask)

    # 7. Subtle 1.5px Bevel Border Highlight around Squircle Edge
    rim_layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    rim_draw = ImageDraw.Draw(rim_layer)
    rim_draw.rounded_rectangle(
        [inset, inset, size - inset, size - inset],
        radius=corner_radius,
        outline=(255, 255, 255, 45),
        width=int(2.5 * w_scale)
    )
    
    final_icon = Image.alpha_composite(canvas, bg_plate)
    final_icon = Image.alpha_composite(final_icon, rim_layer)
    
    # Downscale from 2048x2048 to 1024x1024 with Lanczos for subpixel antialiasing
    master_1024 = final_icon.resize((1024, 1024), Image.Resampling.LANCZOS)
    return master_1024

def export_iconset(master_1024, iconset_dir):
    """Slice master 1024x1024 icon into all required AppIcon.appiconset PNG sizes."""
    os.makedirs(iconset_dir, exist_ok=True)
    
    slots = [
        ("AppIcon-16.png", 16),
        ("AppIcon-16@2x.png", 32),
        ("AppIcon-32.png", 32),
        ("AppIcon-32@2x.png", 64),
        ("AppIcon-128.png", 128),
        ("AppIcon-128@2x.png", 256),
        ("AppIcon-256.png", 256),
        ("AppIcon-256@2x.png", 512),
        ("AppIcon-512.png", 512),
        ("AppIcon-512@2x.png", 1024),
    ]
    
    for filename, px in slots:
        out_path = os.path.join(iconset_dir, filename)
        if px == 1024:
            resized = master_1024
        else:
            resized = master_1024.resize((px, px), Image.Resampling.LANCZOS)
        resized.save(out_path, format="PNG", optimize=True)
        print(f"Generated {filename} ({px}x{px}) -> {out_path}")

if __name__ == "__main__":
    iconset_path = "Wattly/Assets.xcassets/AppIcon.appiconset"
    print("Generating Wattly Official Dark Matte Ivory W master icon at 2048x2048...")
    master = generate_wattly_master(2048)
    print(f"Exporting 10 PNG slices to {iconset_path}...")
    export_iconset(master, iconset_path)
    
    # Also save a master preview image to interactive/final_app_icon.png
    master.save("interactive/final_app_icon.png", format="PNG")
    print("✓ Successfully updated Wattly AppIconset and saved interactive/final_app_icon.png!")
