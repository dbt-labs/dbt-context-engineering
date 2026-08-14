# 23. Embedding metadata as a cache key, content-hash delta layered onto version_guard

## Status

Accepted, 2026-08-13.

## Concept

An embedding is the output of a **pure function**: `f(text, model, preprocessing) -> vector`.
Treat it like any other cache entry, and the question "what metadata do I need" answers itself:
enough to know whether the cached value still matches what the function would produce today, and
enough to scope an incident to exactly the rows it touched. `version_guard` (ADR-0004) already
lives by one axis of this, a corpus embedded by one model version cannot be compared against a
corpus embedded by another. This record generalizes that single-axis check into a fuller cache key,
without discarding the mechanism that already exists.

## Context

Before this record, the governed incremental AI model pattern stamped exactly two things per
embedded row: the raw vector, and `model_version` read from `var('embedding_model')`. That value
is recorded from **intent**, not **observation**. It will always agree with the config, including
in the case where the actual API call disagreed with it (a floating model alias resolving to a
different snapshot, a dimension-truncation setting changing the vector while the model name stays
identical).

There was also a sharper, unrelated gap in the incremental mechanics.
`incremental_delta_predicate` drove the delta with one test, `unique_key not in (select unique_key
from this)`, which only catches brand-new keys. `version_guard` catches the other known case, a
model-version bump reprocesses the entire corpus. Between those two there was no answer for a row
whose key already exists and whose stored version still matches, but whose *source text changed*.
Nothing re-embedded it, and nothing flagged that it was stale, until someone forced a full refresh.

## Decision

**Every embedded row carries six columns, not two, and the incremental delta gains a second,
finer-grained condition that catches a changed row within a steady-state run.**

The six columns: `embedding` (unchanged), `model_version` (unchanged shape, now audit-only, see
Consequences), `content_hash`, `embedding_dimension`, `embedding_fn_fingerprint`, `embedded_at`.
`embedding_logic_hash` is a seventh, related but separately decided in ADR-0025.

```sql
{% set fingerprint = dbt_context_engineering.embedding_fn_fingerprint(model=var('embedding_model')) %}
{% set delta = dbt_context_engineering.incremental_delta_predicate('doc_id', fingerprint,
    'embedding_fn_fingerprint', content_hash_column='content_hash') %}
select
    doc_id,
    '{{ var("embedding_model") }}'                     as model_version,
    content_hash,
    {{ dbt_context_engineering.embed('body') }}        as embedding,
    {{ dbt_context_engineering.embedding_dimension(dbt_context_engineering.embed('body')) }} as embedding_dimension,
    '{{ fingerprint }}'                                as embedding_fn_fingerprint,
    '{{ run_started_at }}'                             as embedded_at
from {{ ref('stg_docs_hashed') }}
{% if delta %}where {{ delta }}{% endif %}
```

`incremental_delta_predicate` gains an optional `content_hash_column` argument, extended in place
rather than as a sibling macro, so it emits:

```sql
<unique_key> not in (select <unique_key> from <this>)
or <row_value_not_in([unique_key, content_hash_column], this)>
```

`row_value_not_in()` (`macros/incremental/row_value_not_in.sql`) is its own dispatched primitive,
not inlined, because the row-value comparison itself diverges per engine (see Reasoning).

`version_guard`'s comparison target switches, for the embedding pattern specifically, from
`model_version` to `embedding_fn_fingerprint`. No code change to `version_guard` or
`incremental_delta_predicate`'s existing `version`/`version_column` machinery was needed to do
this, both already compare an arbitrary `(value, column)` pair; the only change is what the
canonical pattern passes in.

The full README pattern (`## Governed incremental AI model`) shows the shape with a required
staging step, `content_hash` has to be a real column somewhere upstream of the embedding model,
not a same-`SELECT` alias filtered on in the same query, and not something `guard_batch`/
`log_ai_run` can meter unless their `relation` actually carries it.

## Reasoning

**Why `content_hash` and `embedding_fn_fingerprint` are two columns, not one.** They answer
different questions. `content_hash` answers "did the text change." `embedding_fn_fingerprint`
answers "did the function that would produce today's vector for this row change," a dimension or
provider-parameter bump, with the text held constant. Dropping either collapses two independent
failure modes into one blind spot: without the fingerprint, a same-text function change (the
doc's own headline example is Matryoshka-style dimension truncation) goes undetected by
`content_hash`, which only ever looks at the input; without the hash, a same-model text edit on an
existing key goes undetected by the fingerprint, which never looks at row data at all.

**Why `embedding_fn_fingerprint` excludes chunking config.** Any chunking or preprocessing change
that actually alters the assembled text already surfaces as a `content_hash` mismatch, computed
over the exact string `embed()` receives. Folding chunk config into the fingerprint would only
duplicate what `content_hash` already detects, for no additional coverage.

**Why the delta predicate is a row-value `NOT IN`, not a correlated subquery.** Tried first, and
wrong: a correlated form (`content_hash != (select ...)` or `not exists (select ... where
t.unique_key = unique_key)`) hits a real SQL scoping trap whenever the correlated column names
match on both sides, which they always will here. An unqualified reference inside the subquery
resolves to the subquery's own same-named column, not the outer row, standard SQL name resolution,
not a duckdb quirk. Confirmed empirically, not assumed: the scalar form surfaced as duckdb
rejecting `guard_batch`'s aggregate cost-estimate query with "more than one row returned by a
subquery," and the `EXISTS` form had the identical bug but surfaced silently instead, the condition
never fired for a genuine change. Row-value `NOT IN` needs no alias and no correlation, so there is
no inner scope to shadow the outer one, the same reason the original key-existence check never had
this problem.

**Why a null content_hash freezes the row instead of re-triggering or erroring.** A tuple
comparison against a null value evaluates to null under three-valued logic on duckdb, so `WHERE`
excludes the row automatically, no explicit guard needed for an already-embedded row whose text
later goes null. Confirmed live on Snowflake and Databricks too, though with a nuance worth
recording precisely rather than assuming: both return an actual `FALSE` for this case, not `NULL`,
practically identical for `WHERE`-clause purposes, "excluded, frozen" either way, but not the exact
same three-valued-logic behavior duckdb exhibits. Either way this is a property of null-comparison
semantics, not a feature this macro implements on purpose, and is recorded here so it isn't
rediscovered from scratch. A brand-new row with currently-null text is a different, narrower case
(the key-existence check is true regardless of content, `TRUE OR ...` is `TRUE`), handled by
documentation at the call site (`where body is not null`), not a package macro, since
`chunk`/`attach_metadata` are shipped, tested elsewhere, and reopening either is scope past what a
single null-text row needs.

**Why `row_value_not_in` is its own dispatched macro instead of inlined string concatenation.**
The row-value comparison itself turned out to diverge, confirmed live against real connections to
all four engines, not assumed from ANSI's row-value-constructor spec: BigQuery rejects the plain
form (`(a, b) not in (select a, b from t)`, "Subquery of type IN must have only one output
column") and needs the subquery's SELECT list wrapped as a single tuple, and that wrapped form is
then rejected by both Snowflake and Databricks in turn. Three-vs-one is exactly the shape this
package's `array_agg`/`contains`-style dispatch primitives exist for, isolate the one line that
diverges, keep everything else shared.

**Why `version_guard` didn't need to change to point at the fingerprint.** Its signature was
already generic over `(pinned_version, version_column)`; the mechanism doesn't care what the
string represents. Pointing the embedding pattern's own call at the fingerprint instead of
`model_version` is a call-site change, not a library change, and doesn't affect the existing
generic version-gating tests (`versioned`, `guard_delta`, etc.) that already exercise it with an
arbitrary column name.

## Consequences

- **A model/dimension/provider-parameter bump re-embeds the whole corpus automatically**, and a
  single edited row gets caught and re-embedded within a steady-state run, closing the gap this
  record opens with.
- **`model_version` keeps being stamped, but does no mechanical work.** It's a plain audit column,
  human-readable, denormalized against the fingerprint, kept for the same reason the source doc
  keeps a plain model-name column even once a real cache key exists: nobody wants to reverse a hash
  to answer "which model made this row."
- **Row-value `NOT IN` support was confirmed live on Snowflake, Databricks, and BigQuery, and one
  of the three genuinely diverges.** BigQuery rejects the plain form entirely and needs its
  subquery wrapped as a single tuple; Snowflake and Databricks both reject that wrapped form in
  turn. `row_value_not_in()` dispatches the one line that differs, and the fix was re-confirmed
  against the actual shipped macro, then the full suite re-run clean, on all four engines. See
  Reasoning above for the errors each engine returned before the fix. The full two-build scenario,
  not just the standalone predicate, is mirrored and confirmed on all three cloud warehouses
  (`content_hash_delta_sf`/`_dbx`/`_bq`), including BigQuery's own merge log reporting exactly one
  row processed on the phase-2 build.
- **The null/empty-text guard and source-column provenance are documentation, not enforcement.**
  Both are call-site guidance in the README rather than package macros, a deliberate scope
  boundary, not an oversight; see the README's governed-incremental-model section for the reasoning
  behind each.
- **A pre-existing orphaning gap is unaffected by this record**, and worth stating so it isn't
  confused with something this ADR fixes: a `chunk_id` that `chunk()` stops producing after a
  re-chunk, an absence, not a null value, is invisible to both the key-existence check and the
  content-hash comparison, since neither one runs against a key that no longer appears in the
  source at all. That's surfaced with a `relationships` test between an embedding model and
  `chunk()`'s current output (`orphan_chunks`/`orphan_embeddings`, mirrored as
  `orphan_chunks_sf`/`_dbx`/`_bq` and `orphan_embeddings_sf`/`_dbx`/`_bq`), not fixed with deletion
  logic this package has deliberately avoided elsewhere (ADR-0004). The negative control, a
  deliberate re-chunk making the relationships test actually fail, is confirmed on duckdb and all
  three cloud warehouses.
- Related: ADR-0004 (version-aware incremental refresh, the mechanism this record extends),
  ADR-0024 (inline vs. side-table storage), ADR-0025 (`embedding_logic_hash`, the code-identity
  axis this record deliberately excludes from the fingerprint).

## Glossary

- **Cache key**: the combination of values that must all match for a stored result to still be
  valid to reuse. Here, `(content_hash, embedding_fn_fingerprint)` together identify whether a
  stored vector still matches what calling `embed()` would produce right now.
- **Three-valued logic**: SQL's `NULL` is neither true nor false; comparing anything to `NULL`
  yields `NULL`, and a `WHERE` clause only keeps rows where the condition is `TRUE`, so a `NULL`
  comparison result behaves like `FALSE` for filtering purposes without actually being `FALSE`.
  This is what makes the null-hash "frozen row" behavior happen automatically.
- **Correlated subquery**: a subquery that references a column from the outer query, evaluated
  once per outer row. The scoping trap in Reasoning is specific to this shape; a plain (uncorrelated)
  subquery, like the original key-existence check, doesn't have it.
- **Row-value constructor**: SQL syntax for comparing a tuple of columns at once, `(a, b) IN
  (SELECT x, y FROM ...)`, treating the pair as a single unit rather than writing two separate
  comparisons joined by `AND`/`OR`.
