# 2. Attach source metadata as a separate, non-dispatched macro

- Status: Accepted
- Date: 2026-07-30

## Concept

Two operations look like one feature but are not. **Chunking** packs ordered text into
token-bounded chunks and carries genuine per-engine risk in its ordered aggregation. **Attaching
metadata** carries a value that is *constant per partition key* onto every chunk of that partition.
The second is a **collapse plus a join**, plain ANSI SQL with no dialect divergence to hide.

The design principle is **composition over parameters**. When a concern has no per-engine risk, it
belongs in its own macro composed as a later step, not threaded as flags through a macro that does.
Bolting the simple concern onto the risky one does not simplify the pipeline; it drags an unrelated
feature through the one place that is dangerous to touch.

## Context

A chunk needs to carry source-level fields so downstream consumers can filter, cite, and present it:
a document title, a resolvable citation link, call participants. The first attempt added
`frontmatter_columns` and `frontmatter_in_text` parameters to `ce_chunk`, and `passthrough_columns`
to `ce_split_sentences`, so the fields rode through the split and chunk steps onto every chunk row.

That entangled an unrelated concern with the one part of `ce_chunk` that carries real per-engine
risk: its ordered array and string aggregation, which is **dispatched** per dialect. Restructuring
`ce_chunk`'s projection to thread metadata through introduced a BigQuery bug that had nothing to do
with metadata. The restructured SQL referenced a `SELECT`-list alias later in the same `SELECT`,
which BigQuery does not resolve even though Snowflake, Databricks, and duckdb do.

Two ways to carry the fields:

1. **Parameters on `ce_chunk` / `ce_split_sentences`.** Threads a metadata concern through the
   dispatched projection, which is where the per-engine risk lives. This is the version that hit the
   BigQuery alias bug.
2. **A separate step after chunking.** A collapse to one row per key plus a join, needing none of
   the dispatched machinery. This is the path we chose.

## Decision

**We will attach metadata with a separate macro, `ce_attach_metadata`, composed as a step after
`ce_chunk` rather than as parameters on it.** The macro is not dispatched, because it has no
per-engine divergence to hide. `ce_chunk` and `ce_split_sentences` know nothing about metadata and
stay that way.

```sql
-- models/chunks_with_metadata.sql
{{ dbt_context_engineering.ce_attach_metadata(
     chunks_relation=ref('chunks'),
     metadata_relation=ref('documents'),
     metadata_key_column='document_id',
     metadata_columns=['title', 'citation_url'],
     in_text=false) }}
```

The metadata relation is collapsed with `SELECT DISTINCT` to one row per key, then left-joined onto
the chunks on `partition_key`. To dodge the same BigQuery alias trap that motivated the split, the
possibly-prefixed `chunk_text` is computed in a subquery column, never as a same-`SELECT` alias.

## Reasoning

**Why separate the macro instead of extending `ce_chunk`.** The two concerns have opposite risk
profiles. Chunking's aggregation is per-engine and fragile; metadata attach is portable and dull. A
change to the dull concern should never be able to break the fragile one, and the only way to
guarantee that is to keep them in different macros.

**Why not dispatched.** Dispatch exists to hide real per-dialect divergence. Attach has none: the
collapse, the join, and the cast to a common string type behave the same on all four engines. A
dispatched version would add indirection with nothing to hide behind it.


## Consequences

- **The chunking macros keep a single responsibility** and their dispatched internals stay untouched
  by an unrelated feature, which removes the class of bug the first attempt hit.
- **Attach is portable and independently testable**, and any relation with a source-level grain can
  feed it, not just `ce_chunk` output.
- **The functional-dependency contract is self-enforcing** through the `DISTINCT` collapse and the
  `chunk_id` uniqueness test, so a broken dependency surfaces as a failure rather than a silently
  chosen value.
- **The cost is one extra model and step** in the pipeline rather than a flag on an existing model.
- This **supersedes the parameters-on-`ce_chunk` approach**. See
  [0003](0003-generic-metadata-explicit-provenance.md) for how the columns are treated and
  [0005](0005-in-text-additive-metadata.md) for what `in_text` does.

## Glossary

- **Dispatch**: dbt's mechanism for selecting a different macro implementation per warehouse
  adapter. Used here only for ordered array and string aggregation, which genuinely differ by
  engine.
- **Partition key**: the column that identifies a source object (for example `document_id` or
  `call_id`). All chunks of one source share its partition key, and metadata is constant across
  them.
- **Functional dependency**: the property that a column's value is determined by the key: each
  partition key maps to exactly one value of the metadata column. The contract `ce_attach_metadata`
  assumes and the `chunk_id` uniqueness test enforces.
- **Frontmatter**: relational attributes of a source, such as customer, participants, or assignee.
- **Provenance**: a resolvable link back to the source object, such as a `citation_url`, that lets
  a consumer cite where an answer came from.
- **ANSI SQL**: the portable core of SQL that behaves the same across engines, as opposed to
  dialect-specific constructs that require dispatch.
