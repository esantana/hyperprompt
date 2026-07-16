#!/usr/bin/env bash
# test_model_read.sh — acceptance test: can the model READ the prompt
# rendered in the image? Generates the image(s) with hyperprompt.sh, sends
# them to the API asking for a verbatim transcription and compares it with
# the original text.
#
# Requires: curl, python3 and ANTHROPIC_API_KEY exported.
#   export ANTHROPIC_API_KEY=sk-ant-...
#
# Usage:
#   ./test_model_read.sh                    # uses test_prompt.txt
#   ./test_model_read.sh my_prompt.txt
#   MODEL=claude-haiku-4-5 ./test_model_read.sh   # test another model
#   THRESHOLD=0.995 ./test_model_read.sh          # require more accuracy
#
# Exits 0 if the similarity (after normalizing spaces/line breaks, which
# legitimately change with canvas wrapping) is >= THRESHOLD (default 0.98).
set -euo pipefail
cd "$(dirname "$0")"

TXT="${1:-test_prompt.txt}"
export MODEL="${MODEL:-claude-opus-4-8}"
export THRESHOLD="${THRESHOLD:-0.98}"
: "${ANTHROPIC_API_KEY:?export ANTHROPIC_API_KEY before running}"
[[ -f "$TXT" ]] || { echo "error: file '$TXT' does not exist" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== generating image(s) from $TXT"
./hyperprompt.sh -o "$TMP/page.png" < "$TXT"

TRANSCRIPT="$TMP/transcript.txt"
: > "$TRANSCRIPT"

for png in "$TMP"/page*.png; do
  echo "== sending $(basename "$png") to $MODEL"
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
    sys.exit(f"API error: {r['error']['type']}: {r['error']['message']}")
if r.get("stop_reason") == "max_tokens":
    print("warning: transcription truncated at max_tokens", file=sys.stderr)
print("\n".join(b["text"] for b in r["content"] if b["type"] == "text"))
PY
done

echo "== comparing transcription with the original"
python3 - "$TXT" "$TRANSCRIPT" <<'PY'
import difflib, os, re, sys

def norm(path):
    return re.sub(r"\s+", " ", open(path).read()).strip()

orig, got = norm(sys.argv[1]), norm(sys.argv[2])
sm = difflib.SequenceMatcher(None, orig, got)
ratio = sm.ratio()
print(f"similarity: {ratio:.4f}  ({len(orig)} chars in the original, {len(got)} transcribed)")
shown = 0
for op, i1, i2, j1, j2 in sm.get_opcodes():
    if op != "equal" and shown < 20:
        print(f"  {op:8s} original={orig[i1:i2]!r}  transcribed={got[j1:j2]!r}")
        shown += 1

thr = float(os.environ["THRESHOLD"])
if ratio >= thr:
    print(f"PASS  (>= {thr})")
else:
    print(f"FAIL  (< {thr})")
    sys.exit(1)
PY
