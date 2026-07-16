#!/usr/bin/env bash
# hyperprompt.sh — converts prompt text into a compact PNG image using the
# hypercube algorithm (Gray code + bit rotation) to extract a decimated
# quadrant. The text is rendered at 2x aligned to 2x2 blocks, so the
# extracted quadrant is identical to the 1x render (lossless).
#
# Usage:
#   ./hyperprompt.sh "prompt text"
#   cat prompt.txt | ./hyperprompt.sh
#
# Options:
#   -o FILE       output file (default: hyperprompt.png)
#   -s N          font size in px (default: 6 = smallest size that reads
#                 comfortably; 5 is the absolute floor, 8 is conservative)
#   -f FONT       path to a .ttf/.ttc font (default: Menlo/Monaco)
#   -m N          max side of the sent tile (default: 512 = best
#                 chars-per-token density; never go above 1568 or the API
#                 resizes the image and destroys the text)
#   -t D          extra tree depth (default: 0 = lossless quadrant; each
#                 level halves the sent tile = 4x fewer tokens, LOSSY)
#   --fuse        with -t: orient the 4 sibling tiles of each level (undo
#                 the Gray-code mirroring/rotation) and average them —
#                 equals a box filter; reads far better than one tile
#   --no-aa       disable antialiasing (hard bitmap font)
#   --debug DIR   save intermediate stages (1x render, 2x canvas,
#                 transformed image with the 4 quadrants)
set -euo pipefail

OUT="hyperprompt.png"
FONTSIZE=6
FONT=""
MAXSIDE=512
TREE=0
FUSE=0
AA=1
DEBUG=""
ARGS=()

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '2,26p'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -s) FONTSIZE="$2"; shift 2 ;;
    -f) FONT="$2"; shift 2 ;;
    -m) MAXSIDE="$2"; shift 2 ;;
    -t) TREE="$2"; shift 2 ;;
    --fuse) FUSE=1; shift ;;
    --no-aa) AA=0; shift ;;
    --debug) DEBUG="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    --) shift; ARGS+=("$@"); break ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

if [[ ${#ARGS[@]} -gt 0 ]]; then
  TEXT="${ARGS[*]}"
else
  TEXT="$(cat)"
fi
[[ -n "$TEXT" ]] || { echo "error: empty text" >&2; exit 1; }

export HYPER_TEXT="$TEXT" HYPER_OUT="$OUT" HYPER_FONTSIZE="$FONTSIZE" \
       HYPER_FONT="$FONT" HYPER_MAXSIDE="$MAXSIDE" HYPER_AA="$AA" \
       HYPER_DEBUG="$DEBUG" HYPER_TREE="$TREE" HYPER_FUSE="$FUSE"

python3 <<'PY'
import math
import os
import sys
import textwrap

from PIL import Image, ImageDraw, ImageFont

text      = os.environ["HYPER_TEXT"]
out_path  = os.environ["HYPER_OUT"]
font_size = int(os.environ["HYPER_FONTSIZE"])
font_path = os.environ["HYPER_FONT"]
max_side  = int(os.environ["HYPER_MAXSIDE"])
tree      = int(os.environ["HYPER_TREE"])
fuse      = os.environ["HYPER_FUSE"] == "1"
aa        = os.environ["HYPER_AA"] == "1"
debug_dir = os.environ["HYPER_DEBUG"]

try:
    import numpy as np
except ImportError:
    np = None

# ----------------------------------------------------------------- font
def load_font():
    candidates = [font_path] if font_path else []
    candidates += [
        "/System/Library/Fonts/Menlo.ttc",
        "/System/Library/Fonts/Monaco.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    ]
    for c in candidates:
        if c and os.path.exists(c):
            return ImageFont.truetype(c, font_size)
    return ImageFont.load_default()

font = load_font()
adv = font.getlength("M")
ascent, descent = font.getmetrics()
line_h = ascent + descent
margin = 2

# -------------------------------------------------------- line wrapping
paragraphs = text.rstrip("\n").split("\n")
gap_h = max(2, line_h // 2)  # blank line becomes a half-height gap

def wrap(cols):
    """List of (text, height_px); a blank line takes half a line height."""
    items = []
    for p in paragraphs:
        if not p.strip():
            items.append(("", gap_h))
        else:
            for ln in textwrap.wrap(p, width=cols, break_long_words=True) or [""]:
                items.append((ln, line_h))
    while items and items[0][0] == "":
        items.pop(0)
    while items and items[-1][0] == "":
        items.pop()
    return items

def paginate(items, side):
    """Break into pages by accumulated pixel height."""
    limit = side - 2 * margin
    pages, page, h = [], [], 0
    for it in items:
        if h + it[1] > limit and page:
            pages.append(page)
            page, h = [], 0
            if it[0] == "":  # don't open a page with a blank line
                continue
        page.append(it)
        h += it[1]
    if page:
        pages.append(page)
    return pages

# the RENDER side may exceed max_side when tree > 0: only the tile
# (render >> tree) is sent, and only the tile must respect the API cap
sides = [s for s in (64, 128, 256, 512, 1024, 2048)
         if 64 <= (s >> tree) <= max_side]
if not sides:
    sys.exit(f"error: no viable side for -m {max_side} -t {tree} "
             f"(tile must be between 64 and {max_side})")

pages, N = None, None
for side in sides:
    c = int((side - 2 * margin) // adv)
    if c < 10:
        continue
    items = wrap(c)
    if sum(h for _, h in items) <= side - 2 * margin:
        N, pages = side, [items]
        break

if pages is None:  # didn't fit one image: paginate at the max side
    N = sides[-1]
    cols = int((N - 2 * margin) // adv)
    pages = paginate(wrap(cols), N)

# ------------------------------------------------------------ 1x render
def render(items, side):
    img = Image.new("L", (side, side), 255)
    d = ImageDraw.Draw(img)
    if not aa:
        d.fontmode = "1"
    y = margin
    for ln, h in items:
        if ln:
            d.text((margin, y), ln, font=font, fill=0)
        y += h
    return img

# --------------------------------- hypercube: Gray code + bit rotation
def gray_encode(n):
    return n ^ (n >> 1)

def gray_decode_np(g):
    g = g.copy()
    for sh in (1, 2, 4, 8, 16):
        g ^= g >> sh
    return g

def gray_decode_int(n):
    p, n = n, n >> 1
    while n:
        p ^= n
        n >>= 1
    return p

def hypercube_transform(big, r=1):
    """Applies leftRotate(vertex, k-r, k) to every pixel (a hypercube
    automorphism). One rotation step (r=1) yields 4 quadrants, each a
    2x-decimated copy; r steps yield a 4^r-leaf tree whose top-left tile
    (side >> r) samples one pixel per 2^r x 2^r block."""
    side = big.width
    m = side.bit_length() - 1          # bits per coordinate
    k = 2 * m                          # hypercube dimension
    mask = (1 << k) - 1
    if np is not None:
        arr = np.asarray(big)
        gx = gray_encode(np.arange(side, dtype=np.int64))
        G = (gx[None, :] << m) | gx[:, None]          # G[y, x]
        G2 = ((G << (k - r)) | (G >> r)) & mask       # leftRotate by k-r
        X1 = gray_decode_np(G2 >> m)
        Y1 = gray_decode_np(G2 & ((1 << m) - 1))
        out = np.empty_like(arr)
        out[Y1, X1] = arr
        return Image.fromarray(out)
    out = Image.new("L", (side, side))
    px_in, px_out = big.load(), out.load()
    for y in range(side):
        gy = gray_encode(y)
        for x in range(side):
            g = (gray_encode(x) << m) | gy
            g2 = ((g << (k - r)) | (g >> r)) & mask
            px_out[gray_decode_int(g2 >> m), gray_decode_int(g2 & ((1 << m) - 1))] = px_in[x, y]
    return out

def fuse_level(arr):
    """One tree level with oriented siblings: hypercube-transform, undo the
    Gray-code reflections (TR mirrored in x, BL in y, BR rotated 180) and
    average the 4 tiles. Identity: equals a 2x2 box filter of the input."""
    side = arr.shape[0]
    m = side.bit_length() - 1
    k = 2 * m
    mask = (1 << k) - 1
    gx = gray_encode(np.arange(side, dtype=np.int64))
    G = (gx[None, :] << m) | gx[:, None]
    G2 = ((G << (k - 1)) | (G >> 1)) & mask
    X1 = gray_decode_np(G2 >> m)
    Y1 = gray_decode_np(G2 & ((1 << m) - 1))
    out = np.empty_like(arr)
    out[Y1, X1] = arr
    h = side // 2
    return (out[:h, :h] + out[:h, h:][:, ::-1]
            + out[h:, :h][::-1, :] + out[h:, h:][::-1, ::-1]) / 4.0

if fuse and tree > 0 and np is None:
    sys.exit("error: --fuse requires numpy")

# ------------------------------------------------------------- pipeline
def out_name(i):
    if len(pages) == 1:
        return out_path
    root, ext = os.path.splitext(out_path)
    return f"{root}-{i + 1}{ext or '.png'}"

if debug_dir:
    os.makedirs(debug_dir, exist_ok=True)

total_chars = len(text)
img_tokens = 0
T = N >> tree                                         # sent tile side
for i, page_lines in enumerate(pages):
    r1x = render(page_lines, N)
    big = transformed = None
    if fuse and tree > 0:
        acc = np.asarray(r1x, dtype=np.float64)
        for _ in range(tree):
            acc = fuse_level(acc)
        tile = Image.fromarray(np.round(acc).astype(np.uint8))
    else:
        big = r1x.resize((2 * N, 2 * N), Image.NEAREST)   # constant 2x2 blocks
        transformed = hypercube_transform(big, r=tree + 1)
        tile = transformed.crop((0, 0, T, T))

    name = out_name(i)
    tile.save(name, optimize=True)
    img_tokens += math.ceil(T * T / 750)
    if debug_dir:
        base = os.path.splitext(os.path.basename(name))[0]
        r1x.save(os.path.join(debug_dir, f"{base}-render1x.png"))
        if big is not None:
            big.save(os.path.join(debug_dir, f"{base}-canvas2x.png"))
            transformed.save(os.path.join(debug_dir, f"{base}-transformed.png"))

    if tree == 0:
        if np is not None:
            exact = np.array_equal(np.asarray(tile), np.asarray(r1x))
        else:
            exact = list(tile.getdata()) == list(r1x.getdata())
        if not exact:
            print("warning: quadrant != 1x render (invariant violated!)",
                  file=sys.stderr)
        print(f"{name}  {T}x{T}px  {os.path.getsize(name)} bytes  "
              f"(lossless quadrant: {'ok' if exact else 'FAILED'})")
    elif fuse:
        box = np.asarray(r1x, dtype=np.float64)
        for _ in range(tree):
            h = box.shape[0] // 2
            box = box.reshape(h, 2, h, 2).mean(axis=(1, 3))
        ok = np.abs(np.asarray(tile, dtype=np.float64) - box).max() <= 0.5
        if not ok:
            print("warning: fused tile != box filter (invariant violated!)",
                  file=sys.stderr)
        print(f"{name}  {T}x{T}px  {os.path.getsize(name)} bytes  "
              f"(tree depth {tree}, fused siblings == {2 ** tree}x box "
              f"filter: {'ok' if ok else 'FAILED'})")
    else:
        print(f"{name}  {T}x{T}px  {os.path.getsize(name)} bytes  "
              f"(tree depth {tree}: lossy {2 ** tree}x decimation of the "
              f"{N}px render)")

text_tokens = max(1, total_chars // 4)
print(f"---")
print(f"text: {total_chars} chars (~{text_tokens} tokens as text)")
print(f"image: {len(pages)} page(s), ~{img_tokens} image tokens "
      f"({T}*{T}/750 per page)")
if img_tokens < text_tokens:
    print(f"estimated savings: {text_tokens / img_tokens:.1f}x")
else:
    print(f"no savings at this size ({img_tokens} >= {text_tokens}); "
          f"text too short to pay off")
PY
