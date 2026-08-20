# 28. attach_metadata goes incremental by composition, not by changing the macro

## Status

Accepted, 2026-08-20.

## Concept

[ADR-0004](0004-version-aware-incremental-refresh.md) and [ADR-0023](0023-embedding-metadata-and-content-hash-delta.md)
already solved "reprocess only the rows that changed" for `embed`, a per-row **cache entry**:
`f(text, model, preprocessing) -> vector`, comparable across runs via a stored key
(`unique_key`, `content_hash`, `embedding_fn_fingerprint`). `attach_metadata`'s output for one
`chunk_id` has the identical shape: `f(chunk row, its one metadata row) -> attached row`, a pure
function of two already-materialized inputs. Where `embed` needed new mechanism
(`incremental_delta_predicate`, `content_hash`), `attach_metadata` needs none, it needs only to be
*wrapped* by the mechanism that already exists, at the model layer, not the macro layer.

## Context

`attach_metadata` (`macros/metadata/attach_metadata.sql`) is a generic transform macro
([ADR-0013](0013-attach-metadata-as-a-separate-macro.md)) that returns a complete `SELECT` statement
used as an entire model body. Every model that calls it today materializes as `table`, rebuilding
in full on every run. Unlike `chunk`, `attach_metadata`'s output for a given
`chunk_id` does not depend on any *other* row: it is one chunk row left-joined to one
`DISTINCT`-collapsed metadata row, keyed on `partition_key`. That independence is exactly the
property `incremental_delta_predicate`'s row-level content-hash delta requires (ADR-0023's
Reasoning: "why the delta predicate is a row-value `NOT IN`, not a correlated subquery" already
assumes per-row independence; it does not need to be re-argued here, only confirmed to hold for
this macro too), and it does hold for `attach_metadata`. Chunking's own boundary-shifting behavior,
the reason this record deliberately stops short of `chunk` itself, is entirely upstream, inside
`chunk`, not inside `attach_metadata`.

`attach_metadata` has no AI cost and no model-version concept, there is no `embedding_model`-style
knob whose value can drift, so nothing here needed `version_guard`. The only gap
`incremental_delta_predicate`'s plain key-existence check leaves open is the one ADR-0023 already
named for `embed`: a key that already exists, unchanged, but whose *content* changed. For
`attach_metadata` that content is two-sided, either the chunk's own text or one of the joined
metadata values, and a plain `unique_key not in (...)` catches neither.

## Decision

**Wrap `attach_metadata`'s output in a `content_hash` over both the chunk text and every
`metadata_columns` value, and gate the model's `WHERE` with the existing
`incremental_delta_predicate`, version omitted. No change to `attach_metadata` itself.**

```sql
-- models/chunks_with_metadata.sql
{{ config(materialized='incremental', unique_key='chunk_id') }}

with attached as (
    {{ dbt_context_engineering.attach_metadata(
        chunks_relation=ref('chunks'), metadata_relation=ref('documents'),
        metadata_key_column='document_id', metadata_columns=['title', 'citation_url']
    ) }}
),
hashed as (
    select *,
        {{ dbt_context_engineering.content_hash(
            "chunk_text || '|' || coalesce(cast(title as " ~ dbt.type_string() ~ "), '') || '|' || coalesce(cast(citation_url as " ~ dbt.type_string() ~ "), '')"
        ) }} as content_hash
    from attached
)
select * from hashed
{% set delta = dbt_context_engineering.incremental_delta_predicate('chunk_id', content_hash_column='content_hash') %}
{% if delta %}where {{ delta }}{% endif %}
```

`attach_metadata`'s own macro output is itself a complete `WITH ... SELECT ... ORDER BY`
statement; it is composed here as one nested CTE (`attached`) inside a larger `WITH`, so
`content_hash` lands as a real column in a later CTE and the delta filters on it in the final
`SELECT`'s `WHERE`, never a same-`SELECT` alias (the BigQuery trap `chunk.sql`'s own comments
document, and the same reason `content_hash_delta_stg.sql` computes its hash in a dedicated
staging model rather than inline). Confirmed live on duckdb and on all three cloud warehouses
(Snowflake, Databricks, BigQuery), including the two-phase scenario on each: phase 1 builds the
full corpus; phase 2, with one document's metadata edited and its chunk text held constant,
reprocesses exactly that document's chunk rows (the merge reports exactly 2 rows, the edited
document's own chunk count, on both Snowflake and BigQuery) and leaves every other row's stamp
untouched (`integration_tests/{duckdb,cloud}/models/attach_metadata_delta.sql`,
`tests/assert_attach_metadata_delta.sql`).

## Reasoning

**Why no macro-level change was needed.** `incremental_delta_predicate` and `content_hash` are
already generic: the first over an arbitrary `(unique_key, content_hash_column)` pair, the second
over an arbitrary text expression. `attach_metadata`'s per-row independence is the only fact a
caller needs to confirm before reusing them, there is no new divergence to isolate, no new
per-engine risk, nothing ADR-0013's separation-of-concerns argument would object to. Changing the
macro to know about incrementality would be teaching it a caller's concern for no capability it
does not already have by composition.

**Why the hash covers both chunk text and metadata, not metadata alone.** A row's content can
drift on either side of the join. Hashing only the metadata values would miss a chunk whose own
text changed upstream (a `chunk` re-run) while its metadata stayed put; hashing only `chunk_text`
would miss exactly the gap this record exists to close, a metadata edit with the chunk text held
constant. Covering both is one hash expression, not two mechanisms, and it needs no per-source
knowledge beyond the `metadata_columns` list the caller already passes to `attach_metadata`.

**Why version_guard plays no role here.** `version_guard` exists because an embedding or a label is
only meaningful relative to others from the same model version, a corpus-wide invariant a partial
reprocess would silently violate. `attach_metadata` has no analogous invariant: there is no model
version to be internally inconsistent with, joining a chunk to stale metadata for one more run
until the delta catches up is not a correctness problem the way mixing two embedding spaces is. So
`incremental_delta_predicate` is called with `version` omitted, gating reprocess-all purely on
`is_incremental()` (first build / `--full-refresh`), the plain-incremental branch that macro's own
docstring already documents for exactly this case.

**Why this is scoped to attach_metadata and explicitly not to chunk.** `attach_metadata`'s output
per key depends on nothing but that one chunk row and its one metadata row. `chunk`'s output for a
given `chunk_seq` depends on the ordering of every unit in its partition, inserting or removing a
unit can shift later chunks' boundaries, a fact a row-level content-hash delta cannot see because
it only ever compares a key to itself, never to its neighbors. Reusing this record's mechanism for
`chunk` without first proving which insertion patterns are boundary-stable would silently trust a
partial reprocess to match a full rebuild in a case where that has not been shown. Deciding what
granularity, if any, is safe to reprocess incrementally for `chunk` is left to a follow-up ADR.

## Consequences

- **A metadata-only edit is caught and reprocessed within a steady-state run** on the
  `attach_metadata` side of incremental recompute for the deterministic layers; `chunk` remains
  open, tracked separately.
- **No change to `attach_metadata`, `incremental_delta_predicate`, or `content_hash`.** The pattern
  is entirely at the model layer, the same kind of reuse ADR-0023 already established for
  `version_guard`'s `(value, column)` genericity.
- **The caller takes on one obligation**: the `content_hash` expression must be kept in sync with
  whatever `metadata_columns` list is passed to `attach_metadata`, there is no automatic derivation.
  A column added to one and not the other is a silent coverage gap, not a compiler error.
- **Confirmed live on duckdb and on all three cloud warehouses** (Snowflake, Databricks, BigQuery,
  2026-08-20), including the two-phase delta scenario on each and, on BigQuery specifically,
  `row_value_not_in`'s wrapped-tuple dispatch (ADR-0023) inside this pattern's own delta predicate,
  the sharpest of the three engines' divergences and the one most likely to have surfaced a
  problem if this reuse were unsound.
- Related: [ADR-0004](0004-version-aware-incremental-refresh.md),
  [ADR-0023](0023-embedding-metadata-and-content-hash-delta.md) (the mechanism this reuses),
  [ADR-0013](0013-attach-metadata-as-a-separate-macro.md) (why attach stays a separate, generic
  macro, the same property this record leans on).

## Glossary

- See [ADR-0023](0023-embedding-metadata-and-content-hash-delta.md)'s glossary for **cache key**,
  **three-valued logic**, **correlated subquery**, and **row-value constructor**; and
  [ADR-0013](0013-attach-metadata-as-a-separate-macro.md)'s for **partition key** and **functional
  dependency**. This record introduces no new terms.
