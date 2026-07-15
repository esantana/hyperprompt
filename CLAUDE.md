# hyperprompt

Text-to-image prompt compression using a Gray-code hypercube automorphism
(pixel labels are hypercube vertices; a bit rotation of the label is a
dimension permutation; the top-left quadrant of the transformed image is a
lossless subsample when the render is 2x block-aligned). Goal: pay image
tokens (side^2/750) instead of text tokens — roughly 4x cheaper for long
text.

## Files
- `hypercube_pureimage.ipynb` — original algorithm (reference).
- `hyperprompt.sh` — text -> square PNG (hypercube quadrant). `-h` for options.
- `test_hyperprompt.sh` — unit tests (run after any change to the scripts).
- `test_prompt.txt` — test fixture (~5.2k chars; fits 512x512 at 6px font).
- `test_model_read.sh` — acceptance test via API (needs ANTHROPIC_API_KEY).
- `hyperchat.sh` — API chat REPL with the image funnel.
- `hyperfunnel.sh` — enable/disable the funnel globally in Claude Code.

## Token-economy rule (always apply)
When ingesting a reference TEXT file larger than ~2,000 characters
(documents, specs, prose — not code you will edit):
1. `./hyperprompt.sh -o <scratchpad>/hyperread.png < file`
2. Read the PNG page(s) with the Read tool instead of the original text.
The `/hyperread <file>` command wraps this flow.

Exceptions — read the original text normally when:
- the file will be edited (Edit requires Read of the real file);
- exact line numbers matter;
- the file is under ~2,000 chars (each image page has a ~88-token floor).

Tip: feed the script paragraphs on long single lines; pre-existing hard
line breaks waste canvas.
