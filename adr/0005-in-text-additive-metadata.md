# 5. `in_text` embeds metadata in addition to the columns, never instead of them

- Status: Accepted
- Date: 2026-07-30

## Context

`ce_attach_metadata` produces metadata for two different readers:

- SQL reads it as columns, for filtering, joining, grouping, and building a citation link at
  retrieval time.
- The embedding model and the LLM read it inside `chunk_text`, so the metadata becomes part of what
  gets vectorized and sent to the model.

The macro's `in_text` flag controls whether the metadata block is embedded into `chunk_text`. The
open question was what `in_text=true` should do to the columns. Replacing them would make `in_text` a
mode switch; leaving them in place makes it additive.

## Decision

`in_text` is additive. The metadata columns are always emitted. When `in_text=true`, the macro also
prepends a `"col: value"` block to `chunk_text` on every chunk and recomputes `token_estimate` to
match. It never drops the columns.

The columns are the canonical, structured copy. The embedded block is a deliberate second rendering
of the same values, placed where the model can read them.

## Consequences

Both readers are served. SQL keeps structured columns to filter and cite on, and the model sees the
metadata inline, so neither has to parse the other's format. This avoids the failure mode a mode
switch would create, where anything needing the title in SQL would have to extract it back out of the
text prefix with a regex.

The `cols` and `text` models have identical schemas, so `in_text` is a non-breaking toggle rather
than a fork. That is what lets one macro cover both cases and keeps the two integration models
structurally the same.

The cost is deliberate duplication. On an embedded row the metadata exists twice, and `in_text=true`
adds tokens to `chunk_text` that the model pays for. That token cost is the intent, since the model
only sees what is in the text, and `token_estimate` is recomputed so it stays honest.

See [0002](0002-attach-metadata-as-a-separate-macro.md) for why metadata attach is a separate macro,
and [0003](0003-generic-metadata-explicit-provenance.md) for why the columns are treated uniformly.
