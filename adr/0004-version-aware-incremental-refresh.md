# 4. Version-aware incremental refresh, no custom materialization

## Status

Accepted.

## Concept

Because AI calls cost money ([ADR-0003](0003-cost-as-a-first-class-output.md)), you don't want to re-embed or re-label a row you've already processed. That makes the case for an **incremental** model: each run touches only the *new* rows. dbt already supports this, an incremental model plus a`unique_key`merges new rows into an existing table.

But embeddings and labels have a property ordinary transformations don't: **they are only
comparable to others produced by the same model version.** A vector from `text-embedding-005` and a
vector from `text-embedding-004` sit in different spaces. Because of this, cosine similarity between them is meaningless. The same is true of labels from two prompt versions. So there are two distinct refresh modes, and the model must know which it's in:

- **Steady state** — the model/prompt version is unchanged → process only the delta (cheap).
- **Version bump** — someone pinned a new embedding model or prompt version → the *entire corpus*
must be reprocessed so it's internally consistent again (expensive, but correct).

Think of it like a **schema migration for a derived column**: normally you append; but when the
definition itself changes, you rebuild every row.

## Context

The natural dbt lever for "rebuild everything" is `config(full_refresh=…)`. It can't work here: dbt
config is evaluated at **parse** time, but "has the version changed?" can only be answered by
reading the stored version **from the table at run time**. A full custom materialization for AI loads was considered and rejected.  it's a lot of surface area and would surprise dbt users, who expect models to behave like models. We wanted the standard incremental machinery, steered by one runtime signal.

## Decision

Ship a **runtime-boolean macro** instead of a materialization:
`ce_version_guard(pinned_version, version_column='model_version')`. It returns `**True`
(reprocess everything)** on first build, on `--full-refresh`, or when the version stored in the
table differs from the pinned one; otherwise `**False`** (process just the delta). The model uses
it to switch its own incremental `WHERE`, and stamps the pinned version on every row so the next
run can compare.

```sql
{{ config(materialized='incremental', unique_key='doc_id') }}
select
    doc_id,
    '{{ var("ce_embedding_model") }}' as model_version,           -- stamp the version
    {{ dbt_context_engineering.ce_embed('body') }} as embedding
from {{ ref('docs') }}
{% if not dbt_context_engineering.ce_version_guard(var('ce_embedding_model')) %}
where doc_id not in (select doc_id from {{ this }})               -- delta only …
{% endif %}                                                       -- … skipped on a version bump
```

On a bump, the guard is `True`, the `WHERE` is skipped, every row is re-embedded, and the
`unique_key` merge **replaces** the old-version rows rather than duplicating them.

## Reasoning

**Why "process only the delta" isn't the whole story.** Cost pressure says: don't reprocess a row you've already embedded. For an ordinary derived column that's the end of it, because each row is independent. Embeddings and labels are different: an embedding is only meaningful *relative to other vectors produced by the same model*. That creates a hidden invariant, the entire corpus must share one model version, or similarity math is nonsense. And that invariant is exactly what a pure "delta" strategy violates: upgrading the model invalidates every existing row, not just the new ones.

**Why there must be two refresh modes, chosen at run time.** From the invariant, two modes fall out:
steady state (version unchanged → process the delta, cheap) and version bump (reprocess the whole
corpus so it's internally consistent again). The model has to know which mode it's in *on each run*. The obstacle is a pure dbt-timing fact: the built-in "rebuild everything" switch is decided at parse time, but "did the stored version change?" can only be answered by reading the table at run time. Parse-time cannot see run-time state. Once you name that gap, the solution is forced. The refresh signal must be a runtime value, not a config flag.

**Why a boolean macro instead of a custom materialization.** This was a deliberate choice about
surface area and surprise. A custom materialization is powerful, but it's a new, opaque thing every
user must trust and learn; it hides the behavior that decides when you spend money re-embedding. A
boolean that simply flips an ordinary incremental model's `WHERE` clause keeps that decision in plain sight. It's still just an incremental model, and a reader can see exactly why rows are or aren't reprocessed. The craft principle: for load-bearing behavior, prefer the smallest mechanism that composes with tools people already understand over a clever one that obscures it.

## Consequences

- A standard incremental model plus one macro, we use nothing a dbt user doesn't already recognize; no bespoke materialization to learn or maintain.
- A model/embedding-version bump re-embeds the whole corpus **automatically**, keeping the vector
space internally consistent; steady-state runs stay cheap.
- The guard reads the table via `run_query`, so it's a no-op at parse time and only acts at run time.
- The interesting behavior (delta vs. full reprocess) only appears **across sequential runs**, so it
is exercised by a dedicated multi-run CI step rather than a single build.

## Glossary

- **Incremental model** — a dbt model that adds/updates only new rows on each run instead of
rebuilding the whole table. The way to avoid re-paying for AI on rows already processed.
- `**unique_key` / merge** — a column dbt uses to tell new rows from existing ones; on an
incremental run it *merges* (updates matching rows, inserts the rest) rather than blindly
appending, so reprocessing replaces old values instead of duplicating them.
- **Materialization** — how dbt turns a model's `SELECT` into a persisted object: a `table` (rebuilt
each run), a `view` (query stored, recomputed on read), an `incremental` table (updated in place
with new rows), or a *custom* strategy you write yourself. Choosing a materialization is choosing
*how and when* the data refreshes. A **custom materialization** is powerful but is bespoke persistence logic every user must learn and trust, which is precisely what this ADR avoids by steering an ordinary `incremental` model instead.
- **Parse time vs. run time** — dbt first *parses* the project (reads config, builds the DAG) and
then *runs* it (executes SQL). Some decisions (like `config()`) are fixed at parse time; reading a
value out of a table can only happen at run time. This gap is the whole reason the guard is a
runtime boolean, not a config flag.
- `**--full-refresh`** — a dbt flag that rebuilds an incremental model from scratch instead of
adding the delta.
- **Delta** — just the new/changed rows since the last run (as opposed to the whole corpus).
- **Embedding version / vector space** — every embedding model maps text into its *own* coordinate
system (its "vector space"). Two vectors are only comparable if they came from the same model:
`text-embedding-005` and `text-embedding-004` place "renewal risk" at different coordinates, so a cosine similarity across them is meaningless. Think of it like comparing prices in two currencies with no conversion rate. This is the invariant that forces a full re-embed on a version change: mix versions and every similarity score silently degrades into noise.
- `**run_query`** — a dbt function that executes SQL during a run and returns the result to Jinja;
the guard uses it to read the version currently stored in the table.

