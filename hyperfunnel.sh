#!/usr/bin/env bash
# hyperfunnel.sh — liga/desliga o funil de imagem (hyperprompt) globalmente
# no Claude Code, para todos os projetos.
#
# Uso:
#   ./hyperfunnel.sh on       instala o comando /hyperread global e a regra
#                             automatica no ~/.claude/CLAUDE.md
#   ./hyperfunnel.sh off      remove ambos (so o bloco marcado; qualquer outro
#                             conteudo seu no CLAUDE.md global e preservado)
#   ./hyperfunnel.sh status   mostra o estado atual
#
# As mudancas valem a partir da PROXIMA inicializacao do Claude Code.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$PROJECT_DIR/hyperprompt.sh"
CMD_DST="$HOME/.claude/commands/hyperread.md"
GLOBAL_MD="$HOME/.claude/CLAUDE.md"
START_MARK="<!-- hyperprompt-funnel:start -->"
END_MARK="<!-- hyperprompt-funnel:end -->"

edit_global_md() {  # $1 = "add" | "remove"
  MODE="$1" GLOBAL_MD="$GLOBAL_MD" SCRIPT="$SCRIPT" \
  START_MARK="$START_MARK" END_MARK="$END_MARK" python3 - <<'PY'
import os

mode   = os.environ["MODE"]
path   = os.environ["GLOBAL_MD"]
script = os.environ["SCRIPT"]
start  = os.environ["START_MARK"]
end    = os.environ["END_MARK"]

block = f"""{start}
## Funil de imagem para economia de tokens (hyperprompt)
Ao ingerir um arquivo de TEXTO de referencia com mais de ~2.000 caracteres
(documentos, specs, prosa - nao codigo a editar):
1. Rode: {script} -o <scratchpad>/hyperread.png < arquivo
2. Leia o(s) PNG(s) gerados com a ferramenta Read em vez do texto original
   (~4x menos tokens; se o texto for longo ha paginas -1.png, -2.png, ...).
3. Confirme "quadrante lossless: ok" na saida do script.
Excecoes - leia o texto original normalmente: arquivo que sera editado na
sessao (Edit exige Read do arquivo real); quando numeros de linha exatos
importam; arquivos com menos de ~2.000 chars (imagem tem piso de ~88
tokens/pagina). O comando /hyperread <arquivo> encapsula esse fluxo.
{end}"""

content = open(path).read() if os.path.exists(path) else ""

# remove bloco existente (idempotente), preservando o resto do arquivo
while start in content and end in content:
    i, j = content.index(start), content.index(end) + len(end)
    content = (content[:i] + content[j:]).strip("\n") + "\n" if (content[:i] + content[j:]).strip() else ""

if mode == "add":
    content = (content.rstrip("\n") + "\n\n" if content.strip() else "") + block + "\n"

if content.strip():
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(content)
elif os.path.exists(path):
    os.remove(path)  # arquivo era so o nosso bloco; remove para nao deixar lixo
PY
}

write_command_file() {
  mkdir -p "$(dirname "$CMD_DST")"
  cat > "$CMD_DST" <<EOF
---
description: Le um arquivo de texto longo como imagem PNG (hyperprompt) para pagar ~4x menos tokens
---
Leia o arquivo \`\$ARGUMENTS\` pelo funil de imagem, para economizar tokens:

1. Rode \`$SCRIPT -o <scratchpad>/hyperread.png < \$ARGUMENTS\` (use o diretorio de scratchpad da sessao para o PNG).
2. Se o texto for longo, o script pagina em \`hyperread-1.png\`, \`hyperread-2.png\`, ... — leia todas as paginas.
3. Leia o(s) PNG(s) com a ferramenta Read e use o conteudo como se tivesse lido o arquivo de texto original.
4. NAO leia o arquivo de texto original — o objetivo e pagar tokens de imagem (lado^2/750, ~4x menos que o texto).
5. Confirme na saida do script a linha "quadrante lossless: ok" e reporte a economia estimada ao usuario.

Restricoes (nesses casos leia o arquivo original normalmente e avise o usuario):
- Arquivos que serao editados nesta sessao — a ferramenta Edit exige Read do arquivo real.
- Quando numeros de linha exatos importam (referencias codigo:linha, diffs).
- Arquivos com menos de ~2.000 caracteres — abaixo disso a imagem custa igual ou mais.
EOF
}

status() {
  local cmd_ok=nao rule_ok=nao
  [[ -f "$CMD_DST" ]] && cmd_ok=sim
  [[ -f "$GLOBAL_MD" ]] && grep -qF "$START_MARK" "$GLOBAL_MD" && rule_ok=sim
  echo "comando /hyperread global : $cmd_ok  ($CMD_DST)"
  echo "regra automatica global   : $rule_ok  ($GLOBAL_MD)"
  if [[ "$cmd_ok" == sim && "$rule_ok" == sim ]]; then
    echo "estado: ATIVO (vale a partir da proxima inicializacao do Claude Code)"
  elif [[ "$cmd_ok" == nao && "$rule_ok" == nao ]]; then
    echo "estado: DESATIVADO"
  else
    echo "estado: PARCIAL — rode './hyperfunnel.sh on' ou 'off' para corrigir"
  fi
}

case "${1:-}" in
  on)
    [[ -x "$SCRIPT" ]] || { echo "erro: $SCRIPT nao existe ou nao e executavel" >&2; exit 1; }
    write_command_file
    edit_global_md add
    echo "funil ATIVADO globalmente."
    status
    ;;
  off)
    rm -f "$CMD_DST"
    edit_global_md remove
    echo "funil DESATIVADO globalmente."
    status
    ;;
  status)
    status
    ;;
  *)
    echo "uso: $0 on|off|status" >&2
    exit 1
    ;;
esac
