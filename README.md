# dbt_context_engineering

A cross-platform dbt package that gives practitioners a reliable, portable toolkit for
**context engineering** — modeling the data that AI agents read — across **Snowflake
(Cortex), Databricks, and BigQuery**.

Every warehouse now exposes AI as SQL functions, but the surfaces diverge enough that teams
rebuild the same primitives per platform: chunking, typed AI calls, prompt versioning, cost
control, retrieval. This package standardizes those primitives so you write the pattern once
and run it on any of the three engines. Everything ships as ordinary dbt models, macros,
seeds, and tests — reviewed in PRs, enforced by tests, traceable in the DAG.

It is **not** an agent, an MCP server, or a serving layer. It produces the governed context
those systems read.

## Core design principle

> Normalize the ~80% that maps cleanly across engines. Make the divergent ~20% explicit
> configuration (never inferred, always documented, fails clearly).

## Status

Built **one phase at a time behind approval gates** — see `CLAUDE.md` and `tasks/`. Phase 0
(scaffolding), Phase 1 (chunking — `ce_chunk`), Phase 2 (AI function wrappers + prompt library +
cost guard), Phase 3 (run log + reconciliation), Phase 4 (incremental pattern +
`ce_version_guard`), Phase 5 (retrieval — `ce_vector_search` + opt-in `ce_create_vector_index`),
and Phase 6 (knowledge base — `ce_knowledge_base`) are complete. Testing posture is
**structure-only** for cloud AI calls (assembled per-dialect SQL is validated, execution deferred
until credentials land), plus **full deterministic execution on duckdb** of chunking, prompt
resolution/rendering, the cost guard, and the AI run log. Cost reconciliation against engine
usage tables is built but LIVE-VALIDATION DEFERRED. See `docs/DECISIONS.md`.

## Repo map

```
CLAUDE.md                  # operating contract for Claude Code — read first
docs/
  ARCHITECTURE.md          # ← start here: the whole package explained for newcomers
  DESIGN_SPEC.md           # full design rationale
  DECISIONS.md             # locked decisions + open items
  PARITY.md                # engine-surface parity (reviewed release artifact)
tasks/                     # phase-by-phase plan; one phase at a time, approval-gated
macros/
  functions/               # ce_generate/classify/extract/embed (adapter.dispatch) + prereq checks
  prompts/                 # ce_prompt / ce_schema (macro-library loader, D4) + ce_render_prompt
  chunking/                # ce_chunk (unit packing) + ce_split_sentences (layer-1 splitter) + ce_array_agg/ce_string_agg
  metadata/                # ce_attach_metadata (non-dispatched: join source-level metadata onto chunks)
  cost/                    # ce_guard_batch (guard) / ce_estimate_tokens / ce_log_ai_run
  incremental/             # ce_version_guard
  retrieval/               # ce_vector_search
  operations/              # ce_create_vector_index (run-operation only)
models/audit/              # ce_ai_run_log (append-only usage/cost log)
prompts/                   # prompt+schema library — one Jinja macro per name+version (D4)
seeds/                     # synthetic fixtures (no real customer data)
integration_tests/         # per-adapter (cloud) projects + duckdb/ (credential-free deterministic tests)
ci/                        # structure-only CI profiles (placeholder creds)
```

## Chunking (`ce_chunk`) — shipped in Phase 1

`ce_chunk` packs ordered, atomic text **units** (a turn for transcripts, a sentence for
documents) into token-bounded chunks that never split a unit, never cross a partition key, and
carry every unit's id into `source_rows` for lineage. Pure window SQL, deterministic, zero AI
cost. Defaults: `ce_chunk_target_tokens = 512`, `ce_chunk_overlap_tokens = 0` (opt-in overlap).
See `docs/DECISIONS.md` D5 and `tasks/phase-1a-chunking-design.md` for the algorithm + research.

```sql
-- Package macros are called qualified with the package name (dbt convention, like dbt_utils.*).
{{ dbt_context_engineering.ce_chunk(
    relation         = ref('stg_gong__transcripts'),
    id_column        = 'utterance_id',   -- lineage -> source_rows
    order_column     = 'turn_index',
    text_column      = 'utterance_text',
    partition_column = 'call_id',        -- chunks never span a call
    label_column     = 'speaker'         -- prefixes "speaker: text" in chunk_text
) }}
```

### Splitting long text (`ce_split_sentences`) — layer-1 staging

`ce_chunk` *packs* pre-split units; it does not *split* a blob. For documents that arrive as one
big text, `ce_split_sentences` is the staging step that turns one text row into one row per
sentence (`sentence_id, document_id, sentence_index, sentence_text`), which you then feed to
`ce_chunk` (unit = sentence). Deterministic, zero AI. Boundary rule is naive (`. ! ?`) and
over-splits abbreviations — for prose that needs better boundaries, split with a real tokenizer
upstream. Transcripts skip this: they already arrive as one row per turn.

```sql
-- documents -> sentences -> token-bounded chunks
{{ dbt_context_engineering.ce_split_sentences(
    relation    = ref('stg__documents'),
    id_column   = 'document_id',   -- lineage -> document_id + sentence_id
    text_column = 'document_text'
) }}
```

Deterministic tests run on **duckdb** (no cloud credentials): `integration_tests/duckdb`. Both
`ce_chunk` and the `ce_split_sentences → ce_chunk` pipeline are also confirmed live on all three
cloud engines.

### Metadata on chunks (`ce_attach_metadata`)

`ce_chunk` and `ce_split_sentences` know nothing about metadata, and stay that way on
purpose. Carrying a source-level field (title, a resolvable citation link, call participants)
onto every chunk row is a `distinct` collapse and a join, plain ANSI SQL with no per-engine
divergence to hide, so it doesn't belong inside a dispatched macro. `ce_attach_metadata` is a
separate, portable macro that composes with their unmodified output as a step after chunking.
`metadata_columns` is semantically agnostic: pass frontmatter fields (customer, participants),
provenance fields (citation_url, recording_url), or any other source-level columns.

```sql
-- documents -> sentences -> token-bounded chunks (both steps unmodified)
{{ dbt_context_engineering.ce_split_sentences(
    relation    = ref('stg__documents'),
    id_column   = 'document_id',
    text_column = 'document_text'
) }}
```

```sql
{{ dbt_context_engineering.ce_chunk(
    relation         = ref('stg_docs_split'),   -- the ce_split_sentences output above
    id_column        = 'sentence_id',
    order_column     = 'sentence_index',
    text_column      = 'sentence_text',
    partition_column = 'document_id'
) }}
```

```sql
-- attach title/citation_url from the ORIGINAL document-level table, joined on document_id
{{ dbt_context_engineering.ce_attach_metadata(
    chunks_relation      = ref('stg_docs_chunks'),   -- the ce_chunk output above
    metadata_relation    = ref('stg__documents'),    -- the document-level table, pre-split
    metadata_key_column  = 'document_id',
    metadata_columns     = ['title', 'citation_url'],
    in_text              = false                     -- default: columns only, not embedded
) }}
```

Same macro, different source. Call-level metadata works identically:

```sql
{{ dbt_context_engineering.ce_attach_metadata(
    chunks_relation      = ref('stg_call_chunks'),
    metadata_relation    = ref('stg__calls'),
    metadata_key_column  = 'call_id',
    metadata_columns     = ['customer', 'participants', 'recording_url']
) }}
```

Each `metadata_columns` value must be constant per key (source-level, not unit-level). The macro
collapses `metadata_relation` with `distinct`, so a key carrying conflicting values fans out the
join and fails the `chunk_id` uniqueness test rather than silently keeping one value. Pass
`in_text=True` to also prepend a `"col: value"` block to `chunk_text` on every chunk, so the
embedding or LLM sees it; `token_estimate` is recomputed to match.

## The dispatch pattern

Every engine-specific macro uses `adapter.dispatch`. Users call one macro; the correct
dialect fires. `ce_generate.sql` is the canonical reference — copy its shape. Package macros
are called **package-qualified** (`dbt_context_engineering.*`), like `dbt_utils.*`.

```sql
-- config(pre_hook="{{ dbt_context_engineering.ce_guard_batch(ref('stg_gong__transcripts'), 'segment_text') }}")
select
    call_id,
    {{ dbt_context_engineering.ce_classify(
        input_column  = 'segment_text',
        prompt        = dbt_context_engineering.ce_prompt('EXAMPLE_signal_classify', 'v3'),
        output_schema = dbt_context_engineering.ce_schema('EXAMPLE_signal_classify', 'v3')
    ) }} as signal
from {{ ref('stg_gong__transcripts') }}
```

`ce_prompt`/`ce_schema` resolve versioned prompt macros (under `prompts/`) to compile-time
literals; `ce_guard_batch` is the pre-hook circuit breaker so no AI call runs unguarded.
Prompt/guard/chunking logic is validated on duckdb; the AI calls themselves are cloud-deferred.

## Governed incremental AI model (Phases 2–4 together)

The full pattern — process only new rows, re-embed on a version bump, guard cost, log every run:

```sql
{{ config(
    materialized  = 'incremental',
    unique_key    = 'doc_id',
    pre_hook      = "{{ dbt_context_engineering.ce_guard_batch(ref('stg_docs'), 'body') }}",
    post_hook     = "{{ dbt_context_engineering.ce_log_ai_run('embed', model_name=var('ce_embedding_model'), relation=this, input_column='body') }}"
) }}
select
    doc_id,
    '{{ var("ce_embedding_model") }}' as model_version,   -- stamp the pinned version
    {{ dbt_context_engineering.ce_embed('body') }} as embedding
from {{ ref('stg_docs') }}
{% if not dbt_context_engineering.ce_version_guard(var('ce_embedding_model')) %}
where doc_id not in (select doc_id from {{ this }})        -- delta only; skipped on version change
{% endif %}
```

`ce_version_guard` returns True (reprocess all) on first build, `--full-refresh`, or when the
stored `model_version` differs from the pinned one — so a model/embedding-version bump re-embeds
the whole corpus, and the `unique_key` merge replaces the old rows. No custom materialization.

## Retrieval (Phase 5)

`ce_vector_search` ranks a corpus by cosine similarity to a query vector — brute-force over the
embedding **column** by default (no index needed), which is the portable, governed baseline:

```sql
{{ dbt_context_engineering.ce_vector_search(
    relation        = ref('doc_embeddings'),
    embedding_column= 'embedding',
    query_embedding = dbt_context_engineering.ce_embed('search text'),  -- or an array literal
    top_k           = 10,
    id_column       = 'doc_id'
) }}
```

For scale, `ce_create_vector_index` (opt-in, `dbt run-operation` **only** — never a model) builds
the engine's external index/service (Snowflake Cortex Search, BigQuery vector index). These are
separately-billed, stateful objects with idle-serving cost and their own lifecycle — drop them
explicitly. Databricks indexes are created via its Vector Search API, not SQL.

## Knowledge base (Phase 6)

`ce_knowledge_base` unifies multiple pre-embedded sources (tickets, calls, notes, …) into one
mart with a common shape — `source_type, source_id, account_key, text, embedding, ts,
citation_url` — so a single search answers "everything about account X" across systems, with
per-source lineage and a resolvable citation link carried into results. **Register a new
source** by adding one dict to the list; `citation_url` is optional per source (omit it for a
source with no resolvable link and that source's rows get `NULL`):

```sql
-- models/knowledge_base.sql
{{ dbt_context_engineering.ce_knowledge_base([
    {'relation': ref('stg_tickets'), 'source_type': 'ticket',
     'source_id': 'ticket_id', 'account_key': 'account_id',
     'text': 'body', 'embedding': 'embedding', 'timestamp': 'created_at',
     'citation_url': 'ticket_url'},
    {'relation': ref('stg_calls'),   'source_type': 'call',
     'source_id': 'call_id',   'account_key': 'account_id',
     'text': 'transcript', 'embedding': 'embedding', 'timestamp': 'call_time',
     'citation_url': 'call_url'}
]) }}
```

Then account-scoped retrieval across all sources at once:

```sql
{{ dbt_context_engineering.ce_vector_search(
    relation=ref('knowledge_base'), embedding_column='embedding',
    query_embedding=dbt_context_engineering.ce_embed('renewal risk'),
    id_column='source_id', select_columns=['source_type', 'citation_url'],
    filter="account_key = 'acme'") }}
```

All embeddings must come from the same model (see `ce_version_guard`). A managed hybrid index
over the mart is the opt-in scale step (`ce_create_vector_index`).

## Configuration

All divergent prerequisites are `vars` (see `dbt_project.yml` §8), visible and documented —
never inferred. BigQuery additionally requires `ce_bq_connection` + `ce_bq_model` (a MODEL
over a Vertex connection, created as a setup step).
