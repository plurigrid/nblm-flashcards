# nblm-flashcards

Generate and drill flashcards from NotebookLM Enterprise notebooks. Covers 1,244 repos across bmorphism/plurigrid ecosystems.

## Setup

```bash
git clone https://github.com/plurigrid/nblm-flashcards.git
cd nblm-flashcards
pip install hy   # for generation + terminal drill
```

For backfill pipeline: install [babashka](https://github.com/babashka/babashka).
For Emacs drill: Emacs 28+.

### GCP auth (generation only)

```bash
gcloud auth login
gcloud config set project merovingians
gcloud services enable aiplatform.googleapis.com
```

## Drill (no GCP needed)

The `flashcards/` directory contains pre-generated decks. Download or generate your own, then drill:

### Terminal

```bash
hy flashcard_drill.hy                          # all cards, shuffled
hy flashcard_drill.hy --repo bmorphism/TIDE    # filter by repo
hy flashcard_drill.hy --quiz                   # multiple choice
hy flashcard_drill.hy --missed                 # retry missed
hy flashcard_drill.hy --mu                     # review mu feedback log
hy flashcard_drill.hy --driller yourname       # attribute your feedback
```

### Emacs

```bash
emacs -nw --load nblm-drill.el
```

| Key | Action |
|-----|--------|
| `SPC` / `RET` | Reveal answer |
| `y` | Got it (correct) |
| `n` | Missed |
| `m` | **MU (無)** — reject the question, provide feedback |
| `s` | Skip |
| `a/b/c/d` | Quiz answer |
| `q` | Quit |

## MU (無) — Bidirectional Feedback

When a question is wrong, misleading, outdated, or assumes a false premise, press `m` to **unask** it. You'll be prompted for a reason. This creates a feedback entry in `flashcards/.mu-feedback.json` that flows back to the card authors.

The mu option is available:
- Before revealing the answer (reject the question's premise)
- After revealing the answer (disagree with the answer)
- During quizzes (none of the options are correct)

Review all mu feedback:
```bash
hy flashcard_drill.hy --mu
```

### Mu feedback format

```json
{
  "q": "the original question",
  "a": "the original answer",
  "repo": "org/repo",
  "mu_reason": "why this question should not be asked",
  "driller": "who rejected it",
  "timestamp": "2026-03-26T..."
}
```

## Generation

```bash
# Full run: 10 cards/source x 300 sources
hy nblm_flashcards.hy --per-source 10 --batch-size 5 --difficulty hard

# Backfill pipeline (creates notebooks, adds sources, generates, merges)
bb nblm_backfill.bb && bb nblm_merge.bb
```

## Portability

All paths are relative to the repo root. Override with:

```bash
export NBLM_FLASHCARDS_DIR=/path/to/your/flashcards
```
