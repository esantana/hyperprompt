#!/usr/bin/env bash
# test_model_read.sh — teste de aceitacao: o modelo consegue LER o prompt
# renderizado na imagem? Gera a(s) imagem(ns) com hyperprompt.sh, envia a
# API pedindo transcricao literal e compara com o texto original.
#
# Requer: curl, python3 e ANTHROPIC_API_KEY exportada.
#   export ANTHROPIC_API_KEY=sk-ant-...
#
# Uso:
#   ./test_model_read.sh                    # usa test_prompt.txt
#   ./test_model_read.sh meu_prompt.txt
#   MODEL=claude-haiku-4-5 ./test_model_read.sh   # testa outro modelo
#   THRESHOLD=0.995 ./test_model_read.sh          # exige mais precisao
#
# Sai com 0 se a similaridade (apos normalizar espacos/quebras de linha,
# que mudam legitimamente com o wrap do canvas) >= THRESHOLD (default 0.98).
set -euo pipefail
cd "$(dirname "$0")"

TXT="${1:-test_prompt.txt}"
export MODEL="${MODEL:-claude-opus-4-8}"
export THRESHOLD="${THRESHOLD:-0.98}"
: "${ANTHROPIC_API_KEY:?exporte ANTHROPIC_API_KEY antes de rodar}"
[[ -f "$TXT" ]] || { echo "erro: arquivo '$TXT' nao existe" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== gerando imagem(ns) de $TXT"
./hyperprompt.sh -o "$TMP/page.png" < "$TXT"

TRANSCRIPT="$TMP/transcript.txt"
: > "$TRANSCRIPT"

for png in "$TMP"/page*.png; do
  echo "== enviando $(basename "$png") para $MODEL"
  python3 - "$png" <<'PY' > "$TMP/payload.json"
import base64, json, os, sys
data = base64.standard_b64encode(open(sys.argv[1], "rb").read()).decode()
print(json.dumps({
    "model": os.environ["MODEL"],
    "max_tokens": 8192,
    "messages": [{"role": "user", "content": [
        {"type": "image",
         "source": {"type": "base64", "media_type": "image/png", "data": data}},
        {"type": "text",
         "text": "Transcribe the text in this image verbatim. Output only the "
                 "transcription, with no commentary, no code fences and no "
                 "corrections of any kind."},
    ]}],
}))
PY
  curl -sS https://api.anthropic.com/v1/messages \
    -H "content-type: application/json" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    --data-binary @"$TMP/payload.json" > "$TMP/resp.json"
  python3 - "$TMP/resp.json" <<'PY' >> "$TRANSCRIPT"
import json, sys
r = json.load(open(sys.argv[1]))
if r.get("type") == "error":
    sys.exit(f"erro da API: {r['error']['type']}: {r['error']['message']}")
if r.get("stop_reason") == "max_tokens":
    print("aviso: transcricao truncada em max_tokens", file=sys.stderr)
print("\n".join(b["text"] for b in r["content"] if b["type"] == "text"))
PY
done

echo "== comparando transcricao com o original"
python3 - "$TXT" "$TRANSCRIPT" <<'PY'
import difflib, os, re, sys

def norm(path):
    return re.sub(r"\s+", " ", open(path).read()).strip()

orig, got = norm(sys.argv[1]), norm(sys.argv[2])
sm = difflib.SequenceMatcher(None, orig, got)
ratio = sm.ratio()
print(f"similaridade: {ratio:.4f}  ({len(orig)} chars no original, {len(got)} transcritos)")
shown = 0
for op, i1, i2, j1, j2 in sm.get_opcodes():
    if op != "equal" and shown < 20:
        print(f"  {op:8s} original={orig[i1:i2]!r}  transcrito={got[j1:j2]!r}")
        shown += 1

thr = float(os.environ["THRESHOLD"])
if ratio >= thr:
    print(f"PASS  (>= {thr})")
else:
    print(f"FAIL  (< {thr})")
    sys.exit(1)
PY
