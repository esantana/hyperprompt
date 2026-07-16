#!/usr/bin/env bash
# hyperchat.sh — chat with Claude where long messages are rendered to an
# image by hyperprompt.sh before sending (input-token savings).
# It is a normal chat with history; the ONLY difference: turns with >=
# HYPER_MIN characters become PNGs and go as image blocks. Short turns go
# as text, because below the threshold an image would cost MORE tokens.
#
# Requires: curl, python3 and ANTHROPIC_API_KEY exported.
#
# Usage:
#   ./hyperchat.sh
#     > hello, how are you?            short text -> sent as text
#     > @docs/specification.txt        file content becomes the turn
#     > :q                             quit
#
# Environment variables:
#   MODEL      model (default: claude-opus-4-8)
#   HYPER_MIN  minimum chars to convert into an image (default: 600)
#   SYSTEM     the agent's system prompt
#   DRY_RUN=1  don't call the API; show what would be sent (for testing)
set -euo pipefail
cd "$(dirname "$0")"

export MODEL="${MODEL:-claude-opus-4-8}"
HYPER_MIN="${HYPER_MIN:-600}"
export SYSTEM="${SYSTEM:-You are a helpful assistant. Some user messages arrive rendered as PNG images to save tokens; read the text in the image and respond to it normally, as if it had been typed.}"
DRY_RUN="${DRY_RUN:-0}"
if [[ "$DRY_RUN" != 1 ]]; then
  : "${ANTHROPIC_API_KEY:?export ANTHROPIC_API_KEY (or run with DRY_RUN=1)}"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HIST="$TMP/history.json"
export TMPPAYLOAD="$TMP/payload.json"
echo "[]" > "$HIST"

echo "hyperchat: model=$MODEL  image-threshold=${HYPER_MIN} chars  (:q to quit)"

while IFS= read -r -e -p $'\n> ' line || break; do
  [[ "$line" == ":q" ]] && break
  [[ -z "${line// /}" ]] && continue

  if [[ "$line" == @* && -f "${line#@}" ]]; then
    text="$(cat "${line#@}")"
    echo "  [file ${line#@}: ${#text} chars]"
  else
    text="$line"
  fi

  # -------------------------------------------- long turn -> image(s)
  imgs=()
  if (( ${#text} >= HYPER_MIN )); then
    rm -f "$TMP"/turn*.png
    if printf '%s' "$text" | ./hyperprompt.sh -o "$TMP/turn.png" > "$TMP/hyper.log" 2>&1; then
      for f in "$TMP"/turn*.png; do imgs+=("$f"); done
      sed 's/^/  [hyperprompt] /' "$TMP/hyper.log" | grep -E "tokens|savings|px" || true
    else
      echo "  [hyperprompt failed; sending as text]" >&2
    fi
  fi

  # ------------------------------------ append user turn to the history
  HYPER_TEXT="$text" python3 - ${imgs[@]+"${imgs[@]}"} <<'PY'
import base64, json, os, sys
hist = json.load(open(os.environ["HIST"]))
imgs = sys.argv[1:]
if imgs:
    content = [{"type": "image",
                "source": {"type": "base64", "media_type": "image/png",
                           "data": base64.standard_b64encode(open(p, "rb").read()).decode()}}
               for p in imgs]
    content.append({"type": "text",
                    "text": "The user's message is rendered in the image(s) above. "
                            "Read it and respond normally."})
else:
    content = os.environ["HYPER_TEXT"]
hist.append({"role": "user", "content": content})
json.dump(hist, open(os.environ["HIST"], "w"))
PY

  # -------------------------------------------------- build payload and send
  python3 - <<'PY' > "$TMP/payload.json"
import json, os
hist = json.load(open(os.environ["HIST"]))
print(json.dumps({
    "model": os.environ["MODEL"],
    "max_tokens": 8192,
    "system": os.environ["SYSTEM"],
    "cache_control": {"type": "ephemeral"},   # caches the history between turns
    "messages": hist,
}))
PY

  if [[ "$DRY_RUN" == 1 ]]; then
    python3 - <<'PY'
import json, os
p = json.load(open(os.environ["TMPPAYLOAD"]))
last = p["messages"][-1]["content"]
if isinstance(last, str):
    print(f"  [dry-run] turn goes as TEXT ({len(last)} chars)")
else:
    n = sum(1 for b in last if b["type"] == "image")
    print(f"  [dry-run] turn goes as {n} IMAGE(s) + short instruction")
print(f"  [dry-run] history: {len(p['messages'])} message(s); payload not sent")
PY
    continue
  fi

  curl -sS https://api.anthropic.com/v1/messages \
    -H "content-type: application/json" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    --data-binary @"$TMP/payload.json" > "$TMP/resp.json"

  # ------------------------------------- print response and update history
  python3 - "$TMP/resp.json" <<'PY'
import json, os, sys
r = json.load(open(sys.argv[1]))
if r.get("type") == "error":
    print(f"  [API error: {r['error']['type']}: {r['error']['message']}]")
    hist = json.load(open(os.environ["HIST"]))
    hist.pop()  # drop the failed turn so the history is not corrupted
    json.dump(hist, open(os.environ["HIST"], "w"))
    sys.exit(0)
text = "\n".join(b["text"] for b in r["content"] if b["type"] == "text")
print()
print(text)
u = r["usage"]
print(f"\n  [tokens: input={u['input_tokens']}"
      f" cache_read={u.get('cache_read_input_tokens', 0)}"
      f" cache_write={u.get('cache_creation_input_tokens', 0)}"
      f" output={u['output_tokens']}]")
hist = json.load(open(os.environ["HIST"]))
hist.append({"role": "assistant", "content": text})
json.dump(hist, open(os.environ["HIST"], "w"))
PY
done
echo
