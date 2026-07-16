#!/usr/bin/env bash
# hyperprompt.sh — converte texto de prompt em imagem PNG compacta usando o
# algoritmo de hipercubo (Gray code + rotacao de bits) para extrair um
# quadrante decimado. O texto e renderizado em 2x alinhado aos blocos 2x2,
# de modo que o quadrante extraido e identico ao render 1x (sem perda).
#
# Uso:
#   ./hyperprompt.sh "texto do prompt"
#   cat prompt.txt | ./hyperprompt.sh
#
# Opcoes:
#   -o ARQ        arquivo de saida (default: hyperprompt.png)
#   -s N          tamanho da fonte em px (default: 6 = menor tamanho com
#                 leitura confortavel; 5 e o piso absoluto, 8 e conservador)
#   -f FONTE      caminho de fonte .ttf/.ttc (default: Menlo/Monaco)
#   -m N          lado maximo do quadrante enviado (default: 512 = melhor
#                 densidade de chars/token; nao passe de 1568 ou a API
#                 redimensiona e destroi o texto)
#   --no-aa       desliga antialiasing (fonte bitmap dura)
#   --debug DIR   salva estagios intermediarios (render 1x, canvas 2x,
#                 imagem transformada com os 4 quadrantes)
set -euo pipefail

OUT="hyperprompt.png"
FONTSIZE=6
FONT=""
MAXSIDE=512
AA=1
DEBUG=""
ARGS=()

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '2,21p'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -s) FONTSIZE="$2"; shift 2 ;;
    -f) FONT="$2"; shift 2 ;;
    -m) MAXSIDE="$2"; shift 2 ;;
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
[[ -n "$TEXT" ]] || { echo "erro: texto vazio" >&2; exit 1; }

export HYPER_TEXT="$TEXT" HYPER_OUT="$OUT" HYPER_FONTSIZE="$FONTSIZE" \
       HYPER_FONT="$FONT" HYPER_MAXSIDE="$MAXSIDE" HYPER_AA="$AA" HYPER_DEBUG="$DEBUG"

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
aa        = os.environ["HYPER_AA"] == "1"
debug_dir = os.environ["HYPER_DEBUG"]

try:
    import numpy as np
except ImportError:
    np = None

# ---------------------------------------------------------------- fonte
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

# ------------------------------------------------------- quebra de linha
paragraphs = text.rstrip("\n").split("\n")
gap_h = max(2, line_h // 2)  # linha em branco vira gap de meia altura

def wrap(cols):
    """Lista de (texto, altura_px); linha vazia ocupa meia altura."""
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
    """Quebra em paginas pela altura acumulada em pixels."""
    limit = side - 2 * margin
    pages, page, h = [], [], 0
    for it in items:
        if h + it[1] > limit and page:
            pages.append(page)
            page, h = [], 0
            if it[0] == "":  # nao abrir pagina com linha em branco
                continue
        page.append(it)
        h += it[1]
    if page:
        pages.append(page)
    return pages

sides = [s for s in (64, 128, 256, 512, 1024, 2048) if s <= max_side]
if not sides:
    sys.exit(f"erro: -m {max_side} pequeno demais (minimo 64)")

pages, N = None, None
for side in sides:
    c = int((side - 2 * margin) // adv)
    if c < 10:
        continue
    items = wrap(c)
    if sum(h for _, h in items) <= side - 2 * margin:
        N, pages = side, [items]
        break

if pages is None:  # nao coube em uma imagem: paginar no lado maximo
    N = sides[-1]
    cols = int((N - 2 * margin) // adv)
    pages = paginate(wrap(cols), N)

# ------------------------------------------------------------ render 1x
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

# --------------------------------- hipercubo: Gray code + rotacao de bits
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

def hypercube_transform(big):
    """Aplica leftRotate(vertex, k-1, k) a cada pixel (automorfismo do
    hipercubo). Saida: 4 quadrantes, cada um uma copia decimada 2x."""
    side = big.width
    m = side.bit_length() - 1          # bits por coordenada
    k = 2 * m                          # dimensao do hipercubo
    mask = (1 << k) - 1
    if np is not None:
        arr = np.asarray(big)
        gx = gray_encode(np.arange(side, dtype=np.int64))
        G = (gx[None, :] << m) | gx[:, None]          # G[y, x]
        G2 = ((G << (k - 1)) | (G >> 1)) & mask       # leftRotate por k-1
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
            g2 = ((g << (k - 1)) | (g >> 1)) & mask
            px_out[gray_decode_int(g2 >> m), gray_decode_int(g2 & ((1 << m) - 1))] = px_in[x, y]
    return out

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
for i, page_lines in enumerate(pages):
    r1x = render(page_lines, N)
    big = r1x.resize((2 * N, 2 * N), Image.NEAREST)   # blocos 2x2 constantes
    transformed = hypercube_transform(big)
    quad = transformed.crop((0, 0, N, N))

    if np is not None:
        exact = np.array_equal(np.asarray(quad), np.asarray(r1x))
    else:
        exact = list(quad.getdata()) == list(r1x.getdata())
    if not exact:
        print("aviso: quadrante != render 1x (invariante violada!)", file=sys.stderr)

    name = out_name(i)
    quad.save(name, optimize=True)
    img_tokens += math.ceil(N * N / 750)
    if debug_dir:
        base = os.path.splitext(os.path.basename(name))[0]
        r1x.save(os.path.join(debug_dir, f"{base}-render1x.png"))
        big.save(os.path.join(debug_dir, f"{base}-canvas2x.png"))
        transformed.save(os.path.join(debug_dir, f"{base}-transformed.png"))
    print(f"{name}  {N}x{N}px  {os.path.getsize(name)} bytes  "
          f"(quadrante lossless: {'ok' if exact else 'FALHOU'})")

text_tokens = max(1, total_chars // 4)
print(f"---")
print(f"texto: {total_chars} chars (~{text_tokens} tokens como texto)")
print(f"imagem: {len(pages)} pagina(s), ~{img_tokens} tokens de imagem "
      f"({N}*{N}/750 por pagina)")
if img_tokens < text_tokens:
    print(f"economia estimada: {text_tokens / img_tokens:.1f}x")
else:
    print(f"sem economia neste tamanho ({img_tokens} >= {text_tokens}); "
          f"texto curto demais para compensar")
PY
