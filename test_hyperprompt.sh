#!/usr/bin/env bash
# test_hyperprompt.sh — testes do hyperprompt.sh e do algoritmo de hipercubo.
# Uso: ./test_hyperprompt.sh
# Sai com 0 se todos os testes passam; imprime PASS/FAIL por teste.
set -uo pipefail
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0

check() {  # check "nome do teste" <condicao...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS  $name"
  else
    echo "FAIL  $name"
    FAILS=$((FAILS + 1))
  fi
}

# ---------------------------------------------------------------- teste 1
# fixture cabe em uma pagina 512x512, transformacao lossless, com economia
OUT1="$(./hyperprompt.sh -o "$TMP/fixture.png" < test_prompt.txt 2>&1)"
RC1=$?
check "fixture: exit code 0"                 test "$RC1" -eq 0
check "fixture: quadrante lossless ok"       grep -q "quadrante lossless: ok" <<<"$OUT1"
check "fixture: pagina unica 512x512"        grep -q "512x512px" <<<"$OUT1"
check "fixture: arquivo PNG existe"          test -s "$TMP/fixture.png"
check "fixture: reporta economia"            grep -q "economia estimada" <<<"$OUT1"
check "fixture: dimensoes reais 512x512" \
  python3 -c "from PIL import Image; img = Image.open('$TMP/fixture.png'); assert img.size == (512, 512), img.size"

# ---------------------------------------------------------------- teste 2
# texto longo com lado maximo 256 -> paginacao em varios arquivos
python3 -c "print(('quadrant legible token render image shell downsample ' * 160))" > "$TMP/long.txt"
OUT2="$(./hyperprompt.sh -m 256 -o "$TMP/paged.png" < "$TMP/long.txt" 2>&1)"
RC2=$?
NPAGES=$(ls "$TMP"/paged-*.png 2>/dev/null | wc -l | tr -d ' ')
NLOSSLESS=$(grep -c "quadrante lossless: ok" <<<"$OUT2")
check "paginacao: exit code 0"               test "$RC2" -eq 0
check "paginacao: gerou multiplas paginas"   test "$NPAGES" -ge 2
check "paginacao: toda pagina lossless"      test "$NLOSSLESS" -eq "$NPAGES"

# ---------------------------------------------------------------- teste 3
# entrada vazia deve falhar
check "entrada vazia: exit code != 0"        bash -c '! ./hyperprompt.sh "" 2>/dev/null'

# ---------------------------------------------------------------- teste 4
# propriedades do algoritmo de hipercubo (independentes do render de texto)
check "algoritmo: permutacao pura + quadrantes distintos + formula do TL" \
  python3 - <<'PY'
import numpy as np

def genc(n): return n ^ (n >> 1)
def gdec(g):
    g = g.copy()
    for sh in (1, 2, 4, 8, 16): g ^= g >> sh
    return g

rng = np.random.default_rng(0)
side, m = 256, 8
k, mask = 2 * m, (1 << 2 * m) - 1
img = rng.integers(0, 256, (side, side), dtype=np.int64)

gx = genc(np.arange(side, dtype=np.int64))
G  = (gx[None, :] << m) | gx[:, None]
G2 = ((G << (k - 1)) | (G >> 1)) & mask
X1, Y1 = gdec(G2 >> m), gdec(G2 & ((1 << m) - 1))
out = np.empty_like(img); out[Y1, X1] = img

# 1. permutacao pura: nenhum valor criado ou perdido (sem interpolacao)
assert np.array_equal(np.sort(out.ravel()), np.sort(img.ravel()))

# 2. os 4 quadrantes sao subamostragens distintas (pontos reais diferentes)
N = side // 2
quads = [out[:N, :N], out[:N, N:], out[N:, :N], out[N:, N:]]
for i in range(4):
    for j in range(i + 1, 4):
        assert not np.array_equal(quads[i], quads[j]), (i, j)

# 3. formula fechada do quadrante TL: amostra jitterada dentro do bloco 2x2
u = np.arange(N); src = 2 * u + (u & 1)
assert np.array_equal(quads[0], img[np.ix_(src, src)])

# 4. base do render 2x: com blocos 2x2 constantes, TL == imagem 1x exata
small = rng.integers(0, 256, (N, N), dtype=np.int64)
big = np.kron(small, np.ones((2, 2), dtype=np.int64))
G2b = ((G << (k - 1)) | (G >> 1)) & mask
Xb, Yb = gdec(G2b >> m), gdec(G2b & ((1 << m) - 1))
outb = np.empty_like(big); outb[Yb, Xb] = big
assert np.array_equal(outb[:N, :N], small)
PY

echo "---"
if [[ "$FAILS" -eq 0 ]]; then
  echo "todos os testes passaram"
else
  echo "$FAILS teste(s) falharam"
  exit 1
fi
