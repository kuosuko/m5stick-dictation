"""Builds the Stick's anti-aliased fonts (M5GFX's VLW format) from Noto Sans TC.

    python make_fonts.py <NotoSansTC[wght].ttf> <out dir>

Needs freetype-py. The TTF is Google Fonts' variable Noto Sans TC (OFL):
https://github.com/google/fonts/tree/main/ofl/notosanstc

body   : what the phone sends back, so every common Traditional character
         (Big5 level 1) plus punctuation.
label  : the small labels and the battery percentage.
title  : the screen titles in ui.cpp only.
clock  : the recording timer.
"""
import os, re, struct, sys
import freetype

ttf, out = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.abspath(__file__))
ui_source = open(os.path.join(here, "..", "src", "ui.cpp"), encoding="utf-8").read()
ui_chars = set("".join(re.findall(r'"([^"]*)"', ui_source)))

ascii_chars = {chr(c) for c in range(0x20, 0x7F)}


def big5_range(lead_from, lead_to):
    chars = set()
    for lead in range(lead_from, lead_to + 1):
        for trail in list(range(0x40, 0x7F)) + list(range(0xA1, 0xFF)):
            try:
                chars.add(bytes([lead, trail]).decode("big5"))
            except UnicodeDecodeError:
                pass
    return chars


common = big5_range(0xA4, 0xC6)    # level 1: the 5,401 common characters
symbols = big5_range(0xA1, 0xA3)   # punctuation and symbols
extra = set("…—‘’“”·・「」『』（）〈〉《》【】！？，。、；：～")
fullwidth = {chr(c) for c in range(0xFF01, 0xFF5F)}

sets = {
    "body": (17, 400, ascii_chars | common | symbols | extra | fullwidth),
    "label": (13, 400, ascii_chars | ui_chars),
    "title": (26, 500, ascii_chars | ui_chars),
    "clock": (46, 300, set("0123456789:")),
}


def build(name, pixels, weight, chars):
    face = freetype.Face(ttf)
    try:
        face.set_var_design_coords((weight,))
    except Exception:
        pass
    face.set_pixel_sizes(0, pixels)
    glyphs = []
    for ch in sorted(chars):
        code = ord(ch)
        if code > 0xFFFF or face.get_char_index(code) == 0:
            continue
        face.load_char(ch, freetype.FT_LOAD_RENDER | freetype.FT_LOAD_TARGET_LIGHT)
        g = face.glyph
        bitmap = g.bitmap
        rows, width = bitmap.rows, bitmap.width
        data = bytes(bitmap.buffer[r * bitmap.pitch + c] for r in range(rows) for c in range(width))
        advance = round(g.advance.x / 64)
        glyphs.append((code, rows, width, min(advance, 255), g.bitmap_top, max(-128, min(127, g.bitmap_left)), data))
    ascent = round(face.size.ascender / 64)
    descent = abs(round(face.size.descender / 64))
    blob = struct.pack(">6i", len(glyphs), 11, pixels, 0, ascent, descent)
    for code, rows, width, advance, top, left, _ in glyphs:
        blob += struct.pack(">7i", code, rows, width, advance, top, left, 0)
    blob += b"".join(g[6] for g in glyphs)
    path = os.path.join(out, name + ".vlw")
    with open(path, "wb") as f:
        f.write(blob)
    print(f"{name}: {len(glyphs)} glyphs, {pixels}px, weight {weight}, {len(blob) / 1024:.0f} KB")


os.makedirs(out, exist_ok=True)
for name, (pixels, weight, chars) in sets.items():
    build(name, pixels, weight, chars)
