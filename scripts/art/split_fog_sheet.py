#!/usr/bin/env python3
"""Turn the nano-banana art sheet into this repo's two authored textures.

    python3 scripts/art/split_fog_sheet.py

Reads ``scripts/art/source/fog_sheet.png`` (one render, two items on a flat
chroma backdrop) and writes:

    data/fog_hatch.png   64x64, seamlessly tileable ink cross-hatch on
                         transparent. Drawn over any truth-board cell the
                         seat to move has not proven, so the fog on the
                         board is literally what the mover cannot see.
    data/lens.png        96x96 ink-and-amber reconnaissance lens on
                         transparent. Drawn at the centre of the sense
                         window in recon-hex-5 while it holds.

Gemini does not return alpha and the "pure green" comes back as *some*
green with a tinted edge, so the backdrop colour is taken as the median of
the image border and every pixel's alpha is its distance from it. The hatch
is made seamless by construction rather than by hope: a square of the
generated hatch is downsampled to 32x32 and mirrored into a 64x64 tile,
which matches itself on all four edges by definition.

Pillow is the only dependency:  python3 -m pip install --user pillow
"""
import pathlib
import statistics

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
SHEET = ROOT / "scripts" / "art" / "source" / "fog_sheet.png"
HATCH_OUT = ROOT / "data" / "fog_hatch.png"
LENS_OUT = ROOT / "data" / "lens.png"

INK = (42, 31, 22)          # --ink from client/chrome.css
HATCH_TILE = 64
LENS_SIZE = 96


def backdrop(image):
    """The chroma colour, as the median of the image border."""
    w, h = image.size
    pixels = image.load()
    edge = []
    for x in range(0, w, 4):
        edge.append(pixels[x, 0])
        edge.append(pixels[x, h - 1])
    for y in range(0, h, 4):
        edge.append(pixels[0, y])
        edge.append(pixels[w - 1, y])
    return tuple(
        int(statistics.median([p[i] for p in edge])) for i in range(3)
    )


def distance(pixel, colour):
    return max(abs(pixel[i] - colour[i]) for i in range(3))


def content_box(image, key, tolerance=42):
    """The bounding box of everything that is not the backdrop."""
    w, h = image.size
    pixels = image.load()
    left, top, right, bottom = w, h, 0, 0
    for y in range(h):
        for x in range(w):
            if distance(pixels[x, y], key) > tolerance:
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
    return left, top, right + 1, bottom + 1


def columns_with_content(image, key, tolerance=42):
    w, h = image.size
    pixels = image.load()
    hits = []
    for x in range(w):
        count = 0
        for y in range(0, h, 2):
            if distance(pixels[x, y], key) > tolerance:
                count += 1
        hits.append(count)
    return hits


def split_panels(image, key):
    """Two items in one row: cut on the widest empty column run."""
    hits = columns_with_content(image, key)
    threshold = max(hits) * 0.04
    runs = []
    start = None
    for x, count in enumerate(hits):
        if count <= threshold:
            if start is None:
                start = x
        elif start is not None:
            runs.append((start, x))
            start = None
    if start is not None:
        runs.append((start, len(hits)))
    interior = [r for r in runs if r[0] > 0 and r[1] < len(hits)]
    if not interior:
        raise SystemExit("could not find a gap between the two panels")
    gap = max(interior, key=lambda r: r[1] - r[0])
    cut = (gap[0] + gap[1]) // 2
    return image.crop((0, 0, cut, image.height)), \
        image.crop((cut, 0, image.width, image.height))


def flood_backdrop(image, key, tolerance=62):
    """The backdrop REGION, flood-filled from the border.

    A distance-to-green alpha ramp eats a full-colour object: the amber
    glass of the lens is only ~50 away from the chroma and comes out at a
    fifth of its opacity. Flooding from the border instead keeps every
    pixel the artwork actually drew at full strength, and lets green
    ACCENTS inside an item survive.
    """
    w, h = image.size
    pixels = image.load()
    outside = bytearray(w * h)
    stack = []
    for x in range(w):
        stack.append((x, 0))
        stack.append((x, h - 1))
    for y in range(h):
        stack.append((0, y))
        stack.append((w - 1, y))
    while stack:
        x, y = stack.pop()
        if x < 0 or y < 0 or x >= w or y >= h:
            continue
        index = y * w + x
        if outside[index]:
            continue
        if distance(pixels[x, y], key) > tolerance:
            continue
        outside[index] = 1
        stack.append((x + 1, y))
        stack.append((x - 1, y))
        stack.append((x, y + 1))
        stack.append((x, y - 1))
    return outside


def despill(pixel, key):
    """Drop the chroma spill an AI render leaves on a keyed EDGE pixel.

    Only edge pixels get this: pulling every pixel toward the non-chroma
    channels would eat a colour the artwork meant (an amber glass against a
    magenta key is mostly red, and red is one of magenta's own channels).
    """
    channels = list(pixel[:3])
    top = max(key)
    dominant = [i for i in range(3) if key[i] >= top - 10]
    others = [i for i in range(3) if i not in dominant]
    if not others:
        return tuple(channels)
    cap = max(channels[i] for i in others)
    for index in dominant:
        if channels[index] > cap:
            channels[index] = int(cap + (channels[index] - cap) * 0.35)
    return tuple(channels)


def cut_out(image, key, tolerance=62):
    """RGBA with the flooded backdrop transparent and the item intact."""
    w, h = image.size
    pixels = image.load()
    outside = flood_backdrop(image, key, tolerance)
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    target = out.load()
    for y in range(h):
        for x in range(w):
            if outside[y * w + x]:
                continue
            # Feather the one-pixel rim so the cut does not read as jagged.
            edge = False
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and outside[ny * w + nx]:
                    edge = True
                    break
            pixel = pixels[x, y]
            if distance(pixel, key) <= tolerance:
                # An enclosed patch of the chroma colour INSIDE the item is
                # not backdrop -- the flood could not reach it. It is metal
                # the render filled with the key, so it becomes ink, which
                # is what the sheet was asked for in the first place.
                target[x, y] = INK + (255,)
            elif edge:
                target[x, y] = despill(pixel, key) + (170,)
            else:
                target[x, y] = pixel[:3] + (255,)
    return out


def keyed(image, key, ink=None, tolerance=42, full=120):
    """RGBA: alpha rises with the distance from the backdrop colour."""
    w, h = image.size
    pixels = image.load()
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    target = out.load()
    for y in range(h):
        for x in range(w):
            pixel = pixels[x, y]
            gap = distance(pixel, key)
            if gap <= tolerance:
                continue
            alpha = min(255, int(255 * (gap - tolerance) / (full - tolerance)))
            target[x, y] = (ink or pixel[:3]) + (alpha,)
    return out


def mirror_tile(square):
    """A 32x32 quarter mirrored into a 64x64 tile: seamless by construction."""
    half = HATCH_TILE // 2
    quarter = square.resize((half, half), Image.LANCZOS)
    tile = Image.new("RGBA", (HATCH_TILE, HATCH_TILE), (0, 0, 0, 0))
    tile.paste(quarter, (0, 0))
    tile.paste(quarter.transpose(Image.FLIP_LEFT_RIGHT), (half, 0))
    tile.paste(quarter.transpose(Image.FLIP_TOP_BOTTOM), (0, half))
    tile.paste(
        quarter.transpose(Image.FLIP_LEFT_RIGHT)
        .transpose(Image.FLIP_TOP_BOTTOM), (half, half))
    return tile


def main():
    sheet = Image.open(SHEET).convert("RGB")
    key = backdrop(sheet)
    left, right = split_panels(sheet, key)

    # ---- the hatch ---------------------------------------------------------
    box = content_box(left, key)
    hatch = left.crop(box)
    # Bite well inside the drawn square so the ragged outer edge of the
    # patch never lands in a tile.
    side = min(hatch.size)
    inset = int(side * 0.18)
    hatch = hatch.crop((inset, inset, inset + side - 2 * inset,
                        inset + side - 2 * inset))
    tile = mirror_tile(keyed(hatch, key, ink=INK, tolerance=30, full=110))
    tile.save(HATCH_OUT)

    # ---- the lens ----------------------------------------------------------
    box = content_box(right, key)
    lens = right.crop(box)
    side = max(lens.size)
    square = Image.new("RGB", (side, side), key)
    square.paste(lens, ((side - lens.width) // 2, (side - lens.height) // 2))
    lens = cut_out(square, key)
    lens = lens.resize((LENS_SIZE, LENS_SIZE), Image.LANCZOS)
    lens.save(LENS_OUT)

    for path in (HATCH_OUT, LENS_OUT):
        with Image.open(path) as done:
            print(f"wrote {path.relative_to(ROOT)} {done.size} {done.mode} "
                  f"({path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
