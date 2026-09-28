---
name: dbt-ce-pipeline
description: "Build a retrieval / semantic-search pipeline in a dbt project using the dbt_context_engineering package — chunk, attach metadata, embed, vector search, knowledge base — and make it production-grade (cost guards, run log, incremental re-embed, groundedness/eval tests). Use whenever a user wants to turn a text corpus (transcripts, docs, tickets, emails) into searchable context: semantic search, RAG context tables, retrieval over embeddings, a knowledge base, chunking text for an LLM, embedding a corpus in dbt, or making an existing embed/search model cheaper, incremental, or testable. Trigger even when the user names only one stage (\"chunk my transcripts\", \"embed this table\", \"add vector search\", \"why is my embed model re-processing every row\") — the stages compose into one pipeline and the package's conventions (pinned embedding model, cost gate, incremental re-embed) apply across all. This is for consuming the package in a downstream dbt project, not authoring its macros."
---

# Building a context-engineering pipeline with dbt_context_engineering

This skill is for a **consumer** of the `dbt_context_engineering` package — someone
writing ordinary dbt models in their own project that call the package's macros to
turn raw text into searchable context. Everything the package exposes is called
**package-qualified**, exactly like `dbt_utils`:

```sql
{{ dbt_context_engineering.chunk(...) }}
```

**The macro signatures, arguments, and per-engine notes in this skill and its reference
files are authoritative**, they were verified against the package source. Trust them and
build directly; you do not need to open `dbt_packages/` or the package's `macros/` to
re-confirm a signature this skill already gives you. Reach for the source only when you
need something this skill genuinely doesn't cover (an internal helper, an undocumented
edge) or if you use the authoritative examples and they do not work. This keeps you fast 
and cheap for the common case.

## The mental model

Context engineering is a **pipeline**. Raw text becomes searchable context in a fixed
order, and each stage is an ordinary dbt model:

```
raw text
  → split_sentences   (one row per sentence — a clean unit boundary)
  → chunk             (pack sentences into token-bounded chunks; carries lineage)
  → attach_metadata   (join source title / citation link onto each chunk)   [optional]
  → embed             (turn chunk_text into a vector)
  → knowledge_base    (union many embedded sources into one common shape)
  → vector_search     (rank chunks by cosine similarity to a query)   ── the "read" side
```

The flagship pattern is **semantic search** = `chunk → embed → knowledge_base → vector_search`,
validated end to end on Snowflake, Databricks, and BigQuery. Classification/extraction are a
*precision* enrichment layered on top (see the `dbt-ce-ai-functions` skill), not a
required stage here.

Two facts shape every pipeline:

1. **The embedding model is pinned.** A corpus embedded by one model cannot be searched
   by another. The query vector and the stored vectors must come from the same model.
   Set it in (`var: embedding_model`) and treat a change to it as "re-embed everything."
2. **AI calls cost real money and are gated off by default.** `embed`, `classify`,
   `extract`, `generate`, and `ai_agg` all raise a compiler error unless
   `var: ai_functions_enabled` is `true` for the target. This is a safety feature so a
   fresh checkout or CI run can never accidentally fire a billed call. See the
   `dbt-ce-setup` skill for the full config surface; the minimum for this pipeline is
   `embedding_model` set and `ai_functions_enabled: true`.

## The pipeline, stage by stage

Each stage below is a complete dbt model you can copy and adapt. Read
`references/pipeline-stages.md` for every argument, the exact output columns, and the
per-engine notes.

### 1. Chunk (deterministic, zero AI cost)

`chunk` packs ordered units into token-bounded chunks that never split a unit or cross a
partition key. Feed it one row per unit, often `split_sentences` output, but any table
with an id, an order column, and a text column works. The token estimate is a heuristic
(`ceil(char_length / 4)`), so this stage makes **no AI call and costs nothing**.

```sql
-- models/chunks.sql
{{ config(materialized='table') }}

with sentences as (
    {{ dbt_context_engineering.split_sentences(
        relation    = ref('stg_transcripts'),
        id_column   = 'utterance_id',
        text_column = 'utterance_text'
    ) }}
)
select * from (
    {{ dbt_context_engineering.chunk(
        relation         = 'sentences',
        id_column        = 'sentence_id',
        order_column     = 'sentence_index',
        text_column      = 'sentence_text',
        partition_column = 'document_id'
    ) }}
)
```

`chunk` emits `chunk_id, partition_key, chunk_seq, source_rows, chunk_text,
n_source_rows, token_estimate, exceeds_target, partition_hash`. **`source_rows` is your
lineage** — the ids of every unit that went into the chunk.

### 2. Attach metadata (optional, deterministic)

Join constant-per-source columns (title, citation URL, author) onto each chunk. With
`in_text=True` the metadata is *also* prepended to `chunk_text` (as `"col: value"` lines)
so the embedding sees it, never replacing the columns.

```sql
{{ dbt_context_engineering.attach_metadata(
    chunks_relation     = ref('chunks'),
    metadata_relation   = ref('stg_documents'),
    metadata_key_column = 'document_id',
    metadata_columns    = ['title', 'citation_url'],
    in_text             = false
) }}
```

### 3. Embed

Turn `chunk_text` into a vector. The model comes from `var: embedding_model` (pinned). This
is the first stage that spends money — never a `view` (a view re-embeds on every query; the
package blocks it).

**For any production/real corpus, make embed `incremental`.** A plain `table` re-embeds the
*entire* corpus on every run, which is pure wasted spend at production scale. Reserve `table`
for a quick test or an example/demo project only. The incremental pattern below re-embeds only
rows whose text changed, and re-embeds everything when you change the model (the pinning
invariant). It's short; `references/governance-incremental.md` explains each piece.

```sql
-- models/chunk_embeddings.sql  (production shape: re-embed only what changed)
{{ config(
    materialized='incremental',
    unique_key='chunk_id',
    full_refresh=var('allow_full_reembed', false)
) }}

select
    chunk_id,
    partition_key,
    chunk_text,
    citation_url,
    {{ dbt_context_engineering.content_hash('chunk_text') }} as content_hash,
    '{{ dbt_context_engineering.embedding_fn_fingerprint() }}' as model_version,
    {{ dbt_context_engineering.embed('chunk_text') }} as embedding
from {{ ref('chunks_with_metadata') }}
{% if is_incremental() %}
where {{ dbt_context_engineering.incremental_delta_predicate(
    'chunk_id',
    version=dbt_context_engineering.embedding_fn_fingerprint(),
    content_hash_column='content_hash') }}
{% endif %}
```

Only for a throwaway test or an example project, a plain `table` is acceptable, same
`SELECT`, `materialized='table'`, and drop the `content_hash` / `model_version` columns and
the `is_incremental()` delta. For a scheduled production build, also attach the `guard_batch`
pre-hook and run-log hooks (see the production-grade section below).

### 4. Knowledge base (optional)

When you have several *already-embedded* sources (calls, docs, tickets) and want one
retrieval surface, `knowledge_base` unions them into a common shape:
`source_type, source_id, account_key, text, embedding, ts, citation_url, classification`.
`citation_url` and `classification` are independently optional per source. Build it **before**
search — you search over the unified knowledge base, not the individual source tables. See
`references/pipeline-stages.md` for the source-spec format. (With a single source you can skip
this and search the embeddings table directly.)

### 5. Vector search (the read side)

Brute-force cosine similarity over the embedding column, no index required, works
identically on all engines. Point it at the `knowledge_base` model (or, for a single source,
the embeddings table). Embed the query with the **same** model, then rank.

```sql
{{ dbt_context_engineering.vector_search(
    relation        = ref('knowledge_base'),
    embedding_column= 'embedding',
    query_embedding = dbt_context_engineering.embed('what is driving late deliveries'),
    top_k           = 10,
    id_column       = 'source_id',
    select_columns  = ['citation_url', 'text']
) }}
```

Returns `[id_column, select_columns..., score]`, ordered by score, tie-broken on
`id_column`. A managed vector index (Snowflake Cortex Search, BigQuery vector index,
Databricks Vector Search) is an **opt-in** performance upgrade created via
`dbt run-operation create_vector_index`, it is billed and stateful, so NEVER create it unless explicitly told; 
see `references/pipeline-stages.md`.

## Make it production-grade

A pipeline that builds is not yet a pipeline you can run on a schedule. Three concerns
turn a working model into a safe one.

**Match the user's scope but default the embed to `incremental` for real data.** The
incremental embed (stage 3) is the baseline production shape, not an over-build: a `table`
that re-embeds the whole corpus nightly is the expensive mistake, so reserve `table` for a
throwaway test or example. What you *should* keep proportional to the ask is the surrounding
**governance layer**: the cost guard, run-log hooks, and monitoring below. For a quick
example or a "just show me chunk → embed → search" request, the incremental model alone is a
complete answer; name the guard/run-log/canary as an explicit next step ("when you run this on
a schedule, add a cost guard and the run log; I can wire that up") rather than bundling all of
it unasked. Build the full governance in when the request implies it: they mention cost, a
nightly/scheduled run, a large corpus, or "production." See
`references/governance-incremental.md`.

- **Cost control.** Every AI model should carry a `guard_batch` pre-hook (a circuit
  breaker that raises *before* the model runs if the batch exceeds `max_batch_rows` /
  `max_est_tokens`) and a `log_ai_run` / `complete_ai_run` hook pair that appends to the
  `ai_run_log` audit table. The rule the package holds itself to: **no AI call ships
  without a guard.** Apply it to your models too.
- **Incremental re-embed.** Re-embedding a whole corpus every run is the most common way
  to burn money here. `incremental_delta_predicate` + `content_hash` re-embed only rows
  whose text changed; `version_guard` + `embedding_fn_fingerprint` re-embed *everything*
  when the model changes (because of the pinning invariant). An incremental AI model must
  also set `full_refresh=var('allow_full_reembed', false)` so a stray `--full-refresh`
  on a shared job can't silently re-bill the corpus.
- **Trust.** Retrieval quality is testable without spending AI budget. Read
  `references/trust-evaluation.md` for `grounded` (an extracted quote must actually
  appear in the source), `conforms_to_schema` (a label is in its taxonomy),
  `no_oversized_chunks`, and `eval` (score predictions against a golden column). These
  run in CI on DuckDB with zero AI cost.

## Gotchas that bite consumers

- **`materialized='view'` on any AI model raises a compiler error** — a view recomputes
  the AI call on every query, an unbounded cost. Use `incremental` for production data
  (`table` only for a test or example, since it re-embeds the whole corpus every run).
- **An incremental AI model with no `full_refresh` config also raises** — set
  `full_refresh=var('allow_full_reembed', false)` (or similar) so a reprocess is an
  explicit opt-in, not a side effect of an unrelated `--full-refresh`.
- **Mismatched embedding models = silently wrong search.** Query and corpus vectors must
  come from the same `embedding_model`. If you change it, plan a full re-embed.
- **`embed` on DuckDB has no implementation** — the local deterministic tier can exercise
  chunking, delta, and governance plumbing (with stand-in vectors) but not real
  embeddings. Real vectors need a live warehouse.
- **`vector_search` is `LIVE-VALIDATION DEFERRED` on the cloud engines** — the
  brute-force default is validated on DuckDB; confirm the per-engine cosine SQL against
  your warehouse the first time you run it live.

## Reference files

- `references/pipeline-stages.md` — every macro's arguments, output columns, source-spec
  formats, materialization choices, and per-engine notes (chunk, split_sentences,
  attach_metadata, embed, knowledge_base, vector_search, create_vector_index).
- `references/governance-incremental.md` — cost guards, the run log, incremental
  re-embed (`version_guard`, `incremental_delta_predicate`, `content_hash`,
  `embedding_fn_fingerprint`), the full-refresh gate, and output-token caps.
- `references/trust-evaluation.md` — `grounded`, `conforms_to_schema`,
  `no_oversized_chunks`, and `eval`, with the schema.yml wiring for each.
