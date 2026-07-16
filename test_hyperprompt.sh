#!/usr/bin/env bash
# test_hyperprompt.sh — tests for hyperprompt.sh and the hypercube algorithm.
# Usage: ./test_hyperprompt.sh
# Exits 0 if every test passes; prints PASS/FAIL per test.
set -uo pipefail
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0

check() {  # check "test name" <condition...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS  $name"
  else
    echo "FAIL  $name"
    FAILS=$((FAILS + 1))
  fi
}

# ---------------------------------------------------------------- test 1
# fixture fits one 512x512 page, lossless transform, with savings
OUT1="$(./hyperprompt.sh -o "$TMP/fixture.png" < test_prompt.txt 2>&1)"
RC1=$?
check "fixture: exit code 0"                 test "$RC1" -eq 0
check "fixture: lossless quadrant ok"        grep -q "lossless quadrant: ok" <<<"$OUT1"
check "fixture: single 512x512 page"         grep -q "512x512px" <<<"$OUT1"
check "fixture: PNG file exists"             test -s "$TMP/fixture.png"
check "fixture: reports savings"             grep -q "estimated savings" <<<"$OUT1"
check "fixture: real dimensions 512x512" \
  python3 -c "from PIL import Image; img = Image.open('$TMP/fixture.png'); assert img.size == (512, 512), img.size"

# ---------------------------------------------------------------- test 2
# long text with max side 256 -> pagination into multiple files
python3 -c "print(('quadrant legible token render image shell downsample ' * 160))" > "$TMP/long.txt"
OUT2="$(./hyperprompt.sh -m 256 -o "$TMP/paged.png" < "$TMP/long.txt" 2>&1)"
RC2=$?
NPAGES=$(ls "$TMP"/paged-*.png 2>/dev/null | wc -l | tr -d ' ')
NLOSSLESS=$(grep -c "lossless quadrant: ok" <<<"$OUT2")
check "pagination: exit code 0"              test "$RC2" -eq 0
check "pagination: multiple pages produced"  test "$NPAGES" -ge 2
check "pagination: every page lossless"      test "$NLOSSLESS" -eq "$NPAGES"

# ---------------------------------------------------------------- test 3
# empty input must fail
check "empty input: exit code != 0"          bash -c '! ./hyperprompt.sh "" 2>/dev/null'

# ---------------------------------------------------------------- test 4
# hypercube algorithm properties (independent of text rendering)
check "algorithm: pure permutation + distinct quadrants + TL closed form" \
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

# 1. pure permutation: no value created or lost (no interpolation)
assert np.array_equal(np.sort(out.ravel()), np.sort(img.ravel()))

# 2. the 4 quadrants are distinct subsamples (different real pixels)
N = side // 2
quads = [out[:N, :N], out[:N, N:], out[N:, :N], out[N:, N:]]
for i in range(4):
    for j in range(i + 1, 4):
        assert not np.array_equal(quads[i], quads[j]), (i, j)

# 3. closed form of the TL quadrant: jittered sample inside the 2x2 block
u = np.arange(N); src = 2 * u + (u & 1)
assert np.array_equal(quads[0], img[np.ix_(src, src)])

# 4. basis of the 2x render: with constant 2x2 blocks, TL == exact 1x image
small = rng.integers(0, 256, (N, N), dtype=np.int64)
big = np.kron(small, np.ones((2, 2), dtype=np.int64))
G2b = ((G << (k - 1)) | (G >> 1)) & mask
Xb, Yb = gdec(G2b >> m), gdec(G2b & ((1 << m) - 1))
outb = np.empty_like(big); outb[Yb, Xb] = big
assert np.array_equal(outb[:N, :N], small)
PY

# ---------------------------------------------------------------- test 5
# tree depth: -t 1 sends a half-side tile (4x fewer tokens), lossy
OUT5="$(./hyperprompt.sh -t 1 -o "$TMP/tree.png" < test_prompt.txt 2>&1)"
RC5=$?
check "tree: exit code 0"                    test "$RC5" -eq 0
check "tree: 256x256 tile from 512 render"   grep -q "256x256px" <<<"$OUT5"
check "tree: labeled lossy"                  grep -q "tree depth 1: lossy" <<<"$OUT5"
check "tree: real dimensions 256x256" \
  python3 -c "from PIL import Image; img = Image.open('$TMP/tree.png'); assert img.size == (256, 256), img.size"
./hyperprompt.sh -o "$TMP/ident_default.png" < test_prompt.txt >/dev/null 2>&1
./hyperprompt.sh -t 0 -o "$TMP/ident_t0.png" < test_prompt.txt >/dev/null 2>&1
check "tree: -t 0 byte-identical to default"  cmp -s "$TMP/ident_default.png" "$TMP/ident_t0.png"

echo "---"
if [[ "$FAILS" -eq 0 ]]; then
  echo "all tests passed"
else
  echo "$FAILS test(s) failed"
  exit 1
fi
