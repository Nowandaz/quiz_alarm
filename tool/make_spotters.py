"""Draws the PLACEHOLDER pictures for the sample Pathology spotter questions
into assets/question_images/.

These are simple schematic drawings, not real micrographs. They exist so the
spotter feature can be tested; replace them with real photos (same file
names, or new names referenced from assets/question_banks/pathology.json).

Needs Pillow:  python tool/make_spotters.py
"""
import math
import os
import random

from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "question_images")
W, H, S = 640, 440, 3  # final size and supersampling factor

BG = (250, 238, 240)
RBC = (226, 122, 134)
RBC_PALE = (243, 190, 196)
RBC_DARK = (196, 84, 100)
PURPLE = (92, 58, 150)
PURPLE_DARK = (62, 36, 110)
CYTO = (214, 196, 232)
PINK_CELL = (240, 178, 190)


def canvas(bg=BG):
    img = Image.new("RGB", (W * S, H * S), bg)
    return img, ImageDraw.Draw(img)


def save(img, name):
    img.resize((W, H), Image.LANCZOS).save(os.path.join(OUT, name), optimize=True)
    print(name)


def disc(d, x, y, r, fill, outline=None, width=0):
    d.ellipse([(x - r) * S, (y - r) * S, (x + r) * S, (y + r) * S], fill=fill,
              outline=outline, width=width * S)


def oval(d, x, y, rx, ry, fill):
    d.ellipse([(x - rx) * S, (y - ry) * S, (x + rx) * S, (y + ry) * S], fill=fill)


def poly(d, pts, fill):
    d.polygon([(x * S, y * S) for x, y in pts], fill=fill)


def rbc(d, x, y, r=22):
    disc(d, x, y, r, RBC)
    disc(d, x, y, r * 0.42, RBC_PALE)


def scatter(rng, n, r, avoid=(), margin=30):
    """Random non-overlapping centres."""
    pts = []
    tries = 0
    while len(pts) < n and tries < 5000:
        tries += 1
        x, y = rng.uniform(margin, W - margin), rng.uniform(margin, H - margin)
        if all(math.hypot(x - a, y - b) > r * 2.1 for a, b in pts) and all(
            math.hypot(x - a, y - b) > rr + r for a, b, rr in avoid
        ):
            pts.append((x, y))
    return pts


def crescent(d, x, y, length, angle, fill):
    pts = []
    for i in range(41):
        t = -1 + 2 * i / 40
        pts.append((t * length, -(1 - t * t) * length * 0.42))
    for i in range(41):
        t = 1 - 2 * i / 40
        pts.append((t * length, -(1 - t * t) * length * 0.12))
    ca, sa = math.cos(angle), math.sin(angle)
    poly(d, [(x + px * ca - py * sa, y + px * sa + py * ca) for px, py in pts], fill)


def sickle_cells():
    rng = random.Random(1)
    img, d = canvas()
    sickles = scatter(rng, 9, 46)
    for x, y in scatter(rng, 26, 22, avoid=[(a, b, 44) for a, b in sickles]):
        rbc(d, x, y)
    for x, y in sickles:
        crescent(d, x, y, 44, rng.uniform(0, math.pi), RBC_DARK)
    save(img, "sickle_cells.png")


def target_cells():
    rng = random.Random(2)
    img, d = canvas()
    for i, (x, y) in enumerate(scatter(rng, 38, 25)):
        if i % 3 == 0:
            rbc(d, x, y, 24)
        else:
            disc(d, x, y, 25, RBC)
            disc(d, x, y, 16, RBC_PALE)
            disc(d, x, y, 7.5, RBC_DARK)
    save(img, "target_cells.png")


def rouleaux():
    rng = random.Random(3)
    img, d = canvas()
    for _ in range(9):
        x, y = rng.uniform(70, W - 70), rng.uniform(60, H - 60)
        a = rng.uniform(0, math.pi)
        n = rng.randint(5, 9)
        for i in range(n):
            px = x + math.cos(a) * (i - n / 2) * 13
            py = y + math.sin(a) * (i - n / 2) * 13
            layer = Image.new("RGBA", (60 * S, 60 * S), (0, 0, 0, 0))
            ld = ImageDraw.Draw(layer)
            ld.ellipse([20 * S, 6 * S, 40 * S, 54 * S], fill=RBC + (255,),
                       outline=RBC_DARK + (255,), width=2 * S)
            layer = layer.rotate(-math.degrees(a), resample=Image.BICUBIC)
            img.paste(layer, (int((px - 30) * S), int((py - 30) * S)), layer)
    save(img, "rouleaux.png")


def schistocytes():
    rng = random.Random(4)
    img, d = canvas()
    frags = scatter(rng, 12, 30)
    for x, y in scatter(rng, 24, 22, avoid=[(a, b, 26) for a, b in frags]):
        rbc(d, x, y)
    for i, (x, y) in enumerate(frags):
        a = rng.uniform(0, 2 * math.pi)
        if i % 2 == 0:  # triangle fragment
            pts = [(x + 24 * math.cos(a + k * 2.1), y + 24 * math.sin(a + k * 2.1)) for k in range(3)]
            poly(d, pts, RBC_DARK)
        else:  # helmet cell: a disc with a straight cut
            disc(d, x, y, 22, RBC_DARK)
            cut = [(x + 40 * math.cos(a + t), y + 40 * math.sin(a + t)) for t in (-0.9, 0.9)]
            far = [(x + 60 * math.cos(a + t), y + 60 * math.sin(a + t)) for t in (0.5, -0.5)]
            poly(d, cut + far, BG)
    save(img, "schistocytes.png")


def hypersegmented_neutrophil():
    rng = random.Random(5)
    img, d = canvas()
    cx, cy = W / 2, H / 2
    for x, y in scatter(rng, 26, 22, avoid=[(cx, cy, 95)]):
        rbc(d, x, y)
    disc(d, cx, cy, 82, (238, 214, 226))
    lobes = [(cx + 46 * math.cos(k * math.pi / 3 + 0.3), cy + 42 * math.sin(k * math.pi / 3 + 0.3))
             for k in range(6)]
    for (x1, y1), (x2, y2) in zip(lobes, lobes[1:]):
        d.line([x1 * S, y1 * S, x2 * S, y2 * S], fill=PURPLE, width=4 * S)
    for x, y in lobes:
        disc(d, x, y, 19, PURPLE)
    save(img, "hypersegmented_neutrophil.png")


def malaria_rings():
    rng = random.Random(6)
    img, d = canvas()
    for i, (x, y) in enumerate(scatter(rng, 34, 26)):
        rbc(d, x, y, 25)
        if i % 3 == 0:
            ox, oy = rng.uniform(-8, 8), rng.uniform(-8, 8)
            disc(d, x + ox, y + oy, 8, None, outline=(70, 60, 170), width=2)
            disc(d, x + ox + 7, y + oy - 4, 3, (190, 30, 60))
    save(img, "malaria_rings.png")


def auer_rods():
    rng = random.Random(7)
    img, d = canvas()
    cx, cy = W / 2, H / 2
    for x, y in scatter(rng, 24, 22, avoid=[(cx, cy, 110)]):
        rbc(d, x, y)
    disc(d, cx, cy, 98, CYTO)
    disc(d, cx - 14, cy - 8, 66, PURPLE)
    disc(d, cx - 30, cy - 22, 9, PURPLE_DARK)
    for (x1, y1, x2, y2) in [(cx + 50, cy - 30, cx + 86, cy + 4), (cx + 30, cy + 58, cx + 74, cy + 40),
                             (cx - 20, cy + 64, cx + 14, cy + 84)]:
        d.line([x1 * S, y1 * S, x2 * S, y2 * S], fill=(205, 40, 90), width=5 * S)
    save(img, "auer_rods.png")


def reed_sternberg():
    rng = random.Random(8)
    img, d = canvas((248, 236, 242))
    cx, cy = W / 2, H / 2
    for x, y in scatter(rng, 70, 13, avoid=[(cx, cy, 105)], margin=16):
        disc(d, x, y, 12, PURPLE_DARK)
    oval(d, cx, cy, 104, 82, (236, 200, 216))
    for dx in (-36, 36):
        disc(d, cx + dx, cy, 40, (170, 140, 205), outline=PURPLE, width=3)
        disc(d, cx + dx, cy, 13, (200, 30, 70))
    save(img, "reed_sternberg.png")


def signet_ring():
    rng = random.Random(9)
    img, d = canvas((246, 232, 236))
    for x, y in scatter(rng, 14, 44, margin=50):
        a = rng.uniform(0, 2 * math.pi)
        disc(d, x, y, 42, (232, 190, 205))
        disc(d, x - 5 * math.cos(a), y - 5 * math.sin(a), 33, (226, 236, 248))
        crescent(d, x + 33 * math.cos(a), y + 33 * math.sin(a), 24, a + math.pi / 2, PURPLE_DARK)
    save(img, "signet_ring_cells.png")


def steatosis():
    rng = random.Random(10)
    img, d = canvas((238, 170, 184))
    step = 74
    for row in range(-1, H // step + 2):
        for col in range(-1, W // step + 2):
            x = col * step + (step / 2 if row % 2 else 0) + rng.uniform(-6, 6)
            y = row * step + rng.uniform(-6, 6)
            pts = [(x + 40 * math.cos(k * math.pi / 3 + 0.5), y + 40 * math.sin(k * math.pi / 3 + 0.5))
                   for k in range(6)]
            poly(d, pts, (232, 150, 168))
            d.line([(px * S, py * S) for px, py in pts + pts[:1]], fill=(200, 110, 135), width=2 * S)
            a = rng.uniform(0, 2 * math.pi)
            if rng.random() < 0.75:
                disc(d, x, y, rng.uniform(20, 27), (252, 250, 250))
                disc(d, x + 30 * math.cos(a), y + 30 * math.sin(a), 6, PURPLE_DARK)
            else:
                disc(d, x, y, 9, PURPLE_DARK)
    save(img, "steatosis.png")


os.makedirs(OUT, exist_ok=True)
for make in (sickle_cells, target_cells, rouleaux, schistocytes, hypersegmented_neutrophil,
             malaria_rings, auer_rods, reed_sternberg, signet_ring, steatosis):
    make()
