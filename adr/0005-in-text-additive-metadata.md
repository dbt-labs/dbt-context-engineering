# 5. `in_text` embeds metadata in addition to the columns, never instead of them

- Status: Accepted
- Date: 2026-07-30

## Concept

The same metadata serves **two readers with different eyes**. SQL reads it as **columns**, for
filtering, joining, and building a citation link at retrieval time. The embedding model and the LLM
read only what is inside `chunk_text`, so for them metadata exists only if it is written **into the
text** that gets vectorized and sent.

The design fork is **additive versus mode switch**. A mode switch would make `in_text=true` move the
metadata from columns into text, serving one reader by starving the other. Additive means the same
values appear in both renderings at once. The principle is that a rendering aimed at one reader
should never remove the structured copy the other depends on.

## Context

`ce_attach_metadata` produces metadata for both readers. Its `in_text` flag controls whether a
metadata block is embedded into `chunk_text`. The open question was what `in_text=true` should do to
the columns.

Two options:

1. **Mode switch: embed instead of columns.** `in_text=true` moves the values into `chunk_text` and
   drops the columns. Anything needing the value in SQL would then have to parse it back out of the
   text with a regex.
2. **Additive: embed in addition to columns.** The columns are always emitted; `in_text=true` adds
   a second copy into the text. This is the path we chose.

## Decision

**`in_text` is additive: the metadata columns are always emitted, and `in_text=true` embeds a second
copy into `chunk_text` on top of them, never instead.** When set, the macro prepends a `"col: value"`
block (one line per column, closed with a `---` line) to `chunk_text` on every chunk, and recomputes
`token_estimate` so it reflects the added text.

```text
title: Q3 renewal call
assignee: dana
---
<original chunk_text follows>
```

The columns are the canonical, structured copy. The embedded block is a deliberate second rendering
of the same values, placed where the model can read them.

## Reasoning

**Why additive rather than a mode switch.** The two readers need the same values in different forms
at the same time. A mode switch forces a choice between them, and whichever reader loses has to
reconstruct the data from the other's format. Additive removes the choice: both readers are served
from one call.

**Why recompute `token_estimate`.** The estimate exists to be honest about what the model will
process and pay for. Embedding the block adds real tokens to `chunk_text`, so leaving the estimate
untouched would understate cost. Recomputing keeps the number tied to the text it describes.

**Why identical schemas for the `cols` and `text` cases matter.** Because `in_text=true` only adds
to `chunk_text` and never changes the column set, the two integration models have the same schema.
That makes `in_text` a non-breaking toggle rather than a fork, which is what lets one macro cover
both cases without a second code path to maintain.

## Consequences

- **Both readers are served without either parsing the other's format.** SQL keeps structured
  columns to filter and cite on; the model sees the metadata inline.
- **It avoids the regex failure mode** a mode switch would create, where anything needing a value in
  SQL would have to extract it from the text prefix.
- **The `cols` and `text` models share a schema**, so `in_text` is a non-breaking toggle rather than
  a fork.
- **The cost is deliberate duplication.** On an embedded row the metadata exists twice, and
  `in_text=true` adds tokens the model pays for. That token cost is the intent, and
  `token_estimate` is recomputed so it stays honest.
- See [0002](0002-attach-metadata-as-a-separate-macro.md) for why attach is a separate macro, and
  [0003](0003-generic-metadata-explicit-provenance.md) for why the columns are treated uniformly.

## Glossary

- **`chunk_text`**: the text of a chunk. The only field the embedding model and LLM read, which is
  why metadata must be written into it to reach them.
- **Embedding model**: the model that turns `chunk_text` into a vector. It sees only the text, so
  metadata influences the vector only when embedded in the text.
- **`token_estimate`**: the approximate token count of `chunk_text`, computed as
  `ceil(length / 4)`, used for cost accounting. Recomputed after embedding so it stays accurate.
- **Additive flag**: a flag that adds a rendering without removing an existing one, as opposed to a
  mode switch that swaps one form for another.
- **`cols` / `text` models**: the two integration models exercising `in_text=false` and
  `in_text=true`. They share a schema, which keeps `in_text` a non-breaking toggle.
