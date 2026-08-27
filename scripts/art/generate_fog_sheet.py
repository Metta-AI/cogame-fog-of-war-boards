#!/usr/bin/env python3
"""Generate the fog-of-war-boards art sheet with nano-banana.

    python3 scripts/art/generate_fog_sheet.py

Writes ``scripts/art/source/fog_sheet.png``: ONE render carrying both of
this repo's authored textures side by side on a flat chroma backdrop, so
the two share a style. ``scripts/art/split_fog_sheet.py`` keys, crops and
turns that sheet into ``data/fog_hatch.png`` and ``data/lens.png``.

The key is never printed, never written to a file and never a URL
parameter: it rides in the ``x-goog-api-key`` header and the vault
substitutes it on egress to generativelanguage.googleapis.com only.
"""
import base64
import json
import os
import pathlib
import sys
import urllib.request

MODEL = "gemini-2.5-flash-image"
ENDPOINT = (
    "https://generativelanguage.googleapis.com/v1beta/models/"
    f"{MODEL}:generateContent"
)

PROMPT = """A single wide image containing TWO separate items side by side on a
perfectly flat, solid, uniform pure bright MAGENTA (#FF00FF) background — no
shadows, no gradients, no floor, no text, no labels, no borders. The magenta
will be chroma-keyed out; nothing else in the image may be magenta or pink.
Both items are drawn in the same style: hand-inked letterpress / old
technical-manual engraving in DARK WARM BLACK-BROWN INK (#2a1f16), confident
brush and nib lines. There is NO GREEN anywhere in this image and no colour at
all except the amber stated below.

LEFT — a dense square patch of CROSS-HATCHING: fine hand-drawn ink hatch lines
running diagonally in two directions and crossing each other, evenly dense edge
to edge, filling the whole square patch with no border and no vignette, the way
an engraver shades an unknown region of a map. Uniform density, no focal point.

RIGHT — a RECONNAISSANCE LENS seen face on: a circular hand lens whose thick
riveted rim, rivets and short angled handle (lower right) are all drawn in the
same DARK BLACK-BROWN INK as the hatching, with NO green and NO brass tint in
the metal. Only the round glass inside the rim is coloured: flat warm amber
(#e8a33d), carrying two thin crossed ink sighting lines and a small ring of ink
tick marks just inside the rim, like a surveyor's eyepiece. Symmetrical,
centred, drawn face on."""


def main() -> int:
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        print("GEMINI_API_KEY is not set", file=sys.stderr)
        return 2
    body = {
        "contents": [{"parts": [{"text": PROMPT}]}],
        "generationConfig": {"responseModalities": ["IMAGE"]},
    }
    request = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(body).encode(),
        headers={"x-goog-api-key": key, "content-type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        payload = json.load(response)
    part = next(
        p for p in payload["candidates"][0]["content"]["parts"]
        if "inlineData" in p
    )
    out = pathlib.Path(__file__).resolve().parent / "source" / "fog_sheet.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(base64.b64decode(part["inlineData"]["data"]))
    print(f"wrote {out} ({out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
