#!/usr/bin/env bash
# hyperchat.sh — chat com o Claude onde mensagens longas sao renderizadas em
# imagem pelo hyperprompt.sh antes do envio (economia de tokens de entrada).
# E um chat normal com historico; a UNICA diferenca: turnos com >= HYPER_MIN
# caracteres viram PNG e vao como blocos de imagem. Turnos curtos vao como
# texto, porque abaixo do limiar a imagem custaria MAIS tokens.
#
# Requer: curl, python3 e ANTHROPIC_API_KEY exportada.
#
# Uso:
#   ./hyperchat.sh
#     > ola, tudo bem?                 texto curto -> enviado como texto
#     > @docs/especificacao.txt        conteudo do arquivo vira o turno
#     > :q                             sair
#
# Variaveis de ambiente:
#   MODEL      modelo (default: claude-opus-4-8)
#   HYPER_MIN  minimo de chars para converter em imagem (default: 600)
#   SYSTEM     system prompt do agente
#   DRY_RUN=1  nao chama a API; mostra o que seria enviado (para testes)
set -euo pipefail
cd "$(dirname "$0")"

export MODEL="${MODEL:-claude-opus-4-8}"
HYPER_MIN="${HYPER_MIN:-600}"
export SYSTEM="${SYSTEM:-You are a helpful assistant. Some user messages arrive rendered as PNG images to save tokens; read the text in the image and respond to it normally, as if it had been typed.}"
DRY_RUN="${DRY_RUN:-0}"
if [[ "$DRY_RUN" != 1 ]]; then
  : "${ANTHROPIC_API_KEY:?exporte ANTHROPIC_API_KEY (ou rode com DRY_RUN=1)}"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HIST="$TMP/history.json"
export TMPPAYLOAD="$TMP/payload.json"
echo "[]" > "$HIST"

echo "hyperchat: modelo=$MODEL  limiar-imagem=${HYPER_MIN} chars  (:q para sair)"

while IFS= read -r -e -p $'\n> ' line || break; do
  [[ "$line" == ":q" ]] && break
  [[ -z "${line// /}" ]] && continue

  if [[ "$line" == @* && -f "${line#@}" ]]; then
    text="$(cat "${line#@}")"
    echo "  [arquivo ${line#@}: ${#text} chars]"
  else
    text="$line"
  fi

  # -------------------------------------------- turno longo -> imagem(ns)
  imgs=()
  if (( ${#text} >= HYPER_MIN )); then
    rm -f "$TMP"/turn*.png
    if printf '%s' "$text" | ./hyperprompt.sh -o "$TMP/turn.png" > "$TMP/hyper.log" 2>&1; then
      for f in "$TMP"/turn*.png; do imgs+=("$f"); done
      sed 's/^/  [hyperprompt] /' "$TMP/hyper.log" | grep -E "tokens|economia|px" || true
    else
      echo "  [hyperprompt falhou; enviando como texto]" >&2
    fi
  fi

  # ------------------------------------ anexa turno do usuario ao historico
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

  # -------------------------------------------------- monta payload e envia
  python3 - <<'PY' > "$TMP/payload.json"
import json, os
hist = json.load(open(os.environ["HIST"]))
print(json.dumps({
    "model": os.environ["MODEL"],
    "max_tokens": 8192,
    "system": os.environ["SYSTEM"],
    "cache_control": {"type": "ephemeral"},   # cacheia o historico entre turnos
    "messages": hist,
}))
PY

  if [[ "$DRY_RUN" == 1 ]]; then
    python3 - <<'PY'
import json, os
p = json.load(open(os.environ["TMPPAYLOAD"]))
last = p["messages"][-1]["content"]
if isinstance(last, str):
    print(f"  [dry-run] turno vai como TEXTO ({len(last)} chars)")
else:
    n = sum(1 for b in last if b["type"] == "image")
    print(f"  [dry-run] turno vai como {n} IMAGEM(ns) + instrucao curta")
print(f"  [dry-run] historico: {len(p['messages'])} mensagem(ns); payload nao enviado")
PY
    continue
  fi

  curl -sS https://api.anthropic.com/v1/messages \
    -H "content-type: application/json" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    --data-binary @"$TMP/payload.json" > "$TMP/resp.json"

  # ------------------------------------- imprime resposta e atualiza historico
  python3 - "$TMP/resp.json" <<'PY'
import json, os, sys
r = json.load(open(sys.argv[1]))
if r.get("type") == "error":
    print(f"  [erro da API: {r['error']['type']}: {r['error']['message']}]")
    hist = json.load(open(os.environ["HIST"]))
    hist.pop()  # remove o turno que falhou para nao corromper o historico
    json.dump(hist, open(os.environ["HIST"], "w"))
    sys.exit(0)
text = "\n".join(b["text"] for b in r["content"] if b["type"] == "text")
print()
print(text)
u = r["usage"]
print(f"\n  [tokens: entrada={u['input_tokens']}"
      f" cache_leitura={u.get('cache_read_input_tokens', 0)}"
      f" cache_escrita={u.get('cache_creation_input_tokens', 0)}"
      f" saida={u['output_tokens']}]")
hist = json.load(open(os.environ["HIST"]))
hist.append({"role": "assistant", "content": text})
json.dump(hist, open(os.environ["HIST"], "w"))
PY
done
echo
