---
description: Reads a long text file as a PNG image (via hyperprompt.sh) to pay ~4x fewer tokens
---
Read the file `$ARGUMENTS` through the image funnel, to save tokens:

1. Run `./hyperprompt.sh -o <scratchpad>/hyperread.png < $ARGUMENTS` (use the session's scratchpad directory for the PNG).
2. If the text is long, the script paginates into `hyperread-1.png`, `hyperread-2.png`, ... — read every page.
3. Read the PNG page(s) with the Read tool and use the content as if you had read the original text file.
4. Do NOT read the original text file — the goal is to pay image tokens (side²/750 ≈ 4x less than the text).
5. Confirm the line "lossless quadrant: ok" in the script output and report the estimated savings to the user.

Restrictions (in these cases read the original file normally and tell the user):
- Files that will be edited in this session — the Edit tool requires a Read of the real file.
- When exact line numbers matter (code:line references, diffs).
- Files under ~2,000 characters — below that the image costs the same or more.
