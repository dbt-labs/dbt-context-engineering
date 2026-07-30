# 2. Attach source metadata as a separate, non-dispatched macro

- Status: Accepted
- Date: 2026-07-30

## Context

A chunk needs to carry source-level fields (a document title, a resolvable citation link, call
participants) so that downstream consumers can filter, cite, and present it. The first attempt added
`frontmatter_columns` and `frontmatter_in_text` parameters to `ce_chunk`, and `passthrough_columns`
to `ce_split_sentences`, so the fields rode through the split and chunk steps onto every chunk row.

That approach entangled an unrelated concern with the one part of `ce_chunk` that carries genuine
per-engine risk: its ordered array and string aggregation, which is dispatched per dialect.
Restructuring `ce_chunk`'s projection to thread metadata through introduced a real BigQuery bug that
had nothing to do with metadata. The restructured SQL referenced a `SELECT`-list alias later in the
same `SELECT`, which BigQuery does not resolve even though Snowflake, Databricks, and duckdb do.
Carrying a constant-per-key field onto chunks needs none of that machinery. It is a collapse plus a
join, plain ANSI SQL with no per-engine divergence.

## Decision

We will attach metadata with a separate macro, `ce_attach_metadata`, that composes with the unmodified
output of `ce_chunk` as a step after chunking. It is not dispatched, because it has no per-engine
divergence to hide. `ce_chunk` and `ce_split_sentences` know nothing about metadata and stay that way.

The macro takes the chunk relation, the source relation, the join key, a list of `metadata_columns`, and
an `in_text` flag that controls whether the metadata block is also embedded into `chunk_text`.

## Consequences

The chunking macros keep a single responsibility and their dispatched internals stay untouched by an
unrelated feature, which removes the class of bug the first attempt hit. Metadata attach is portable and
independently testable, and any relation with a source-level grain can feed it. The cost is one extra
model and step in the pipeline rather than a flag on an existing model. This supersedes the
parameters-on-`ce_chunk` approach. See [0003](0003-generic-metadata-explicit-provenance.md) for how the
columns are treated.
