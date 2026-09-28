# Governance & incremental re-embed

This is the half of the pipeline that makes it safe to run on a schedule: bounding cost,
logging every run, and re-embedding only what changed. The package holds itself to one
rule and you should too: **no AI call ships without a cost guard.**

## Cost guard — `guard_batch` (pre-hook circuit breaker)

`guard_batch` counts the rows and estimated tokens a model is about to process and
**raises before the model runs** if it exceeds the ceilings, so a runaway batch fails fast
instead of billing you.

```
guard_batch(relation, input_column=none, filter=none)
```

Wire it as a `pre_hook`. Ceilings are vars: `max_batch_rows` (default 10000),
`max_est_tokens` (default 5,000,000). `estimate_tokens` (the same `ceil(len/4)` heuristic
`chunk` uses) does the counting, so no AI call. `filter` scopes the count to a subset (see
the incremental section: on an incremental model you scope the guard to the *delta*, not
the whole corpus).

```sql
{{ config(
    materialized='table',
    pre_hook="{{ dbt_context_engineering.guard_batch(relation=this, input_column='chunk_text') }}"
) }}
```

`guard_batch` bounds **input** tokens only. To cap output, set `var: max_output_tokens`
(and on BigQuery/Gemini, `var: bq_thinking_budget: 0` for structured tasks, since Gemini
bills its default "thinking" as output tokens). See the `dbt-ce-setup` skill for those.

For a grouped `ai_agg` model, use `guard_agg_batch(relation, input_column,
group_by_column, filter=none)` instead, which bounds per-group tokens against
`var: max_agg_group_tokens`.

`dev_sample_filter(row_limit=none)` gives a portable `QUALIFY row_number() ... <= n` cap
for dev/CI runs (falls back to `var: ai_sample_rows`). It is a dev-experience convenience,
**not** a spend-safety mechanism — that's `guard_batch`'s job.

## The run log — `log_ai_run` / `complete_ai_run`

An append-only, event-sourced audit of every AI model run, written to the `ai_run_log`
table.

```
log_ai_run(function_name, model_name=none, relation=none, input_column=none, filter=none)
complete_ai_run(function_name, model_name=none)
```

- `log_ai_run` appends a `'started'` row with `row_count`, `est_tokens`, and (if
  `var: cost_per_1k_tokens` is set) `est_cost`.
- `complete_ai_run` appends a separate `'completed'` row. Because it runs in the model's
  post-hook, a model that errors never writes `completed`, so a `started` with no
  `completed` is a run that failed. Completion is an existence check, never an UPDATE.

The hook **phase** depends on what `relation`/`filter` reference:
- If they filter to an incremental **delta** using `this` → `log_ai_run` must be a
  **pre_hook** (the delta is only knowable before the run).
- If `relation=this` unfiltered (full table) → `log_ai_run` must be a **post_hook**, and
  only on a fully-rebuilt (`table`) materialization.

```sql
{{ config(
    materialized='table',
    pre_hook="{{ dbt_context_engineering.guard_batch(relation=this, input_column='chunk_text') }}",
    post_hook=[
        "{{ dbt_context_engineering.log_ai_run('embed', relation=this, input_column='chunk_text') }}",
        "{{ dbt_context_engineering.complete_ai_run('embed') }}"
    ]
) }}
```

The `ai_run_log` model ships with the package and is bootstrapped by an `on-run-start`
hook, you don't create it. Point it somewhere with `var: ai_run_log_relation` if you want
it in a specific schema.

## Incremental re-embed — the money saver

Re-embedding the whole corpus every run is the most expensive mistake in this pipeline.
There are **two** reasons to re-embed:

1. **A row's text changed** → re-embed just that row. Detected by `content_hash`.
2. **The embedding model/config changed** → re-embed *everything*, because of the pinning
   invariant (old and new vectors are not comparable). Detected by
   `embedding_fn_fingerprint` fed through `version_guard`.

### The three building blocks

```
content_hash(text_expression)
    -> SHA-256 hex of the EXACT string handed to embed() (post-chunk, post-attach_metadata
       in_text). This is the "did the text change" half of the cache key.

embedding_fn_fingerprint(model=none, dimension=none, extra=none)
    -> a compile-time hash of everything that defines the embed() call besides the input
       text (model, dimension, extra params). This is the "did the model change" half.

version_guard(pinned_version, version_column='model_version')
    -> boolean; True when the model must reprocess ALL rows (first build, a version bump,
       or adopting a table that lacks the version column). Feed it the fingerprint.

incremental_delta_predicate(unique_key, version=none, version_column='model_version',
                            content_hash_column=none)
    -> the WHERE predicate selecting the rows to process this run (or none = full rerun).
       Single source of truth: use the SAME predicate for the model body's WHERE, the
       guard_batch filter, and the log_ai_run filter, so all three agree on the delta.
```

### The canonical incremental embed model

```sql
{{ config(
    materialized='incremental',
    unique_key='chunk_id',
    full_refresh=var('allow_full_reembed', false),   -- REQUIRED: see the full-refresh gate
    pre_hook="{{ dbt_context_engineering.guard_batch(
        relation=this, input_column='chunk_text',
        filter=dbt_context_engineering.incremental_delta_predicate(
            'chunk_id',
            version=dbt_context_engineering.embedding_fn_fingerprint(),
            content_hash_column='content_hash')) }}"
) }}

with src as (
    select
        chunk_id,
        chunk_text,
        {{ dbt_context_engineering.content_hash('chunk_text') }} as content_hash
    from {{ ref('chunks_with_metadata') }}
)
select
    chunk_id,
    chunk_text,
    content_hash,
    '{{ dbt_context_engineering.embedding_fn_fingerprint() }}' as model_version,
    {{ dbt_context_engineering.embed('chunk_text') }} as embedding
from src
{% if is_incremental() %}
where {{ dbt_context_engineering.incremental_delta_predicate(
    'chunk_id',
    version=dbt_context_engineering.embedding_fn_fingerprint(),
    content_hash_column='content_hash') }}
{% endif %}
```

On a normal run this re-embeds only rows whose `content_hash` changed. When you change
`embedding_model`, the fingerprint changes, `version_guard` flips true, the delta predicate
drops its WHERE, and the whole corpus re-embeds and merges on `unique_key`.

## The full-refresh gate (why the `full_refresh` config is required)

An incremental AI model that leaves `full_refresh` unset raises a compiler error on
purpose. `version_guard` already handles a *real* model change; the gate closes a different
hole, a bare `--full-refresh` run **for an unrelated reason on a shared job** would
otherwise silently re-embed your entire corpus. Setting
`full_refresh=var('allow_full_reembed', false)` makes a full re-embed an explicit opt-in
(`dbt build --vars '{allow_full_reembed: true}'`), not an accident.
