#!/usr/bin/env bash
# hyperfunnel.sh — turns the image funnel (hyperprompt) on/off globally in
# Claude Code, for every project.
#
# Usage:
#   ./hyperfunnel.sh on       installs the global /hyperread command and the
#                             automatic rule in ~/.claude/CLAUDE.md
#   ./hyperfunnel.sh off      removes both (only the marked block; any other
#                             content of yours in the global CLAUDE.md is
#                             preserved)
#   ./hyperfunnel.sh status   shows the current state
#
# Changes take effect at the NEXT Claude Code startup.
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
## Image funnel for token savings (hyperprompt)
When ingesting a reference TEXT file larger than ~2,000 characters
(documents, specs, prose - not code you will edit):
1. Run: {script} -o <scratchpad>/hyperread.png < file
2. Read the generated PNG(s) with the Read tool instead of the original
   text (~4x fewer tokens; long texts paginate into -1.png, -2.png, ...).
3. Confirm "lossless quadrant: ok" in the script output.
Exceptions - read the original text normally: files that will be edited in
the session (Edit requires Read of the real file); when exact line numbers
matter; files under ~2,000 chars (images have a ~88 token/page floor).
The /hyperread <file> command wraps this flow.
{end}"""

content = open(path).read() if os.path.exists(path) else ""

# remove any existing block (idempotent), preserving the rest of the file
while start in content and end in content:
    i, j = content.index(start), content.index(end) + len(end)
    content = (content[:i] + content[j:]).strip("\n") + "\n" if (content[:i] + content[j:]).strip() else ""

if mode == "add":
    content = (content.rstrip("\n") + "\n\n" if content.strip() else "") + block + "\n"

if content.strip():
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(content)
elif os.path.exists(path):
    os.remove(path)  # the file was only our block; remove it to leave no litter
PY
}

write_command_file() {
  mkdir -p "$(dirname "$CMD_DST")"
  cat > "$CMD_DST" <<EOF
---
description: Reads a long text file as a PNG image (via hyperprompt.sh) to pay ~4x fewer tokens
---
Read the file \`\$ARGUMENTS\` through the image funnel, to save tokens:

1. Run \`$SCRIPT -o <scratchpad>/hyperread.png < \$ARGUMENTS\` (use the session's scratchpad directory for the PNG).
2. If the text is long, the script paginates into \`hyperread-1.png\`, \`hyperread-2.png\`, ... — read every page.
3. Read the PNG page(s) with the Read tool and use the content as if you had read the original text file.
4. Do NOT read the original text file — the goal is to pay image tokens (side^2/750, ~4x less than the text).
5. Confirm the line "lossless quadrant: ok" in the script output and report the estimated savings to the user.

Restrictions (in these cases read the original file normally and tell the user):
- Files that will be edited in this session — the Edit tool requires a Read of the real file.
- When exact line numbers matter (code:line references, diffs).
- Files under ~2,000 characters — below that the image costs the same or more.
EOF
}

status() {
  local cmd_ok=no rule_ok=no
  [[ -f "$CMD_DST" ]] && cmd_ok=yes
  [[ -f "$GLOBAL_MD" ]] && grep -qF "$START_MARK" "$GLOBAL_MD" && rule_ok=yes
  echo "global /hyperread command : $cmd_ok  ($CMD_DST)"
  echo "global automatic rule     : $rule_ok  ($GLOBAL_MD)"
  if [[ "$cmd_ok" == yes && "$rule_ok" == yes ]]; then
    echo "state: ACTIVE (takes effect at the next Claude Code startup)"
  elif [[ "$cmd_ok" == no && "$rule_ok" == no ]]; then
    echo "state: OFF"
  else
    echo "state: PARTIAL — run './hyperfunnel.sh on' or 'off' to fix"
  fi
}

case "${1:-}" in
  on)
    [[ -x "$SCRIPT" ]] || { echo "error: $SCRIPT does not exist or is not executable" >&2; exit 1; }
    write_command_file
    edit_global_md add
    echo "funnel ENABLED globally."
    status
    ;;
  off)
    rm -f "$CMD_DST"
    edit_global_md remove
    echo "funnel DISABLED globally."
    status
    ;;
  status)
    status
    ;;
  *)
    echo "usage: $0 on|off|status" >&2
    exit 1
    ;;
esac
