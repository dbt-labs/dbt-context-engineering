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
(scaffolding), Phase 1 (chunking — `chunk`), Phase 2 (AI function wrappers + prompt library +
cost guard), Phase 3 (run log), Phase 4 (incremental pattern +
`version_guard`), Phase 5 (retrieval — `vector_search` + opt-in `create_vector_index`),
Phase 6 (knowledge base — `knowledge_base`), and Phase 7 (context evaluation & groundedness —
`grounded`, `conforms_to_schema`, `eval`) are complete. Testing posture: the cloud AI
calls (`generate`, `classify`, `extract`, `embed`, `vector_search`) have **executed
successfully on all three engines** (Snowflake, Databricks, BigQuery) against mock sample data,
alongside **full deterministic execution on duckdb** of chunking, prompt resolution/rendering, the
cost guard, and the AI run log. Not yet validated: execution against real production data at
scale, and cost reconciliation against engine usage tables (built, LIVE-VALIDATION DEFERRED). See
`docs/DECISIONS.md`.
**How to run the tests in each environment — and what to check in the results — is in `TESTING.md`.**
**Every macro is defined with its signature and usage in the [Macro reference](#macro-reference) below.**
**The *why* behind each major design choice is recorded as ADRs in [`adr/`](adr/README.md).**

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
  functions/               # generate/classify/extract/embed (adapter.dispatch) + prereq checks
  prompts/                 # prompt / schema (macro-library loader, D4) + render_prompt
  chunking/                # chunk (unit packing) + split_sentences (layer-1 splitter) + array_agg/string_agg
  metadata/                # attach_metadata (non-dispatched: join source-level metadata onto chunks)
  cost/                    # guard_batch (guard) / estimate_tokens / log_ai_run
  incremental/             # version_guard
  retrieval/               # vector_search
  operations/              # create_vector_index (run-operation only)
  evaluation/              # grounded / conforms_to_schema / eval (+ contains/collapse_ws/norm_text/schema_enum)
models/audit/              # ai_run_log (append-only usage/cost log)
prompts/                   # prompt+schema library — one Jinja macro per name+version (D4)
seeds/                     # synthetic fixtures (no real customer data)
integration_tests/         # per-adapter (cloud) projects + duckdb/ (credential-free deterministic tests)
ci/                        # structure-only CI profiles (placeholder creds)
```

## Chunking (`chunk`) — shipped in Phase 1

`chunk` packs ordered, atomic text **units** (a turn for transcripts, a sentence for
documents) into token-bounded chunks that never split a unit, never cross a partition key, and
carry every unit's id into `source_rows` for lineage. Pure window SQL, deterministic, zero AI
cost. Defaults: `chunk_target_tokens = 512`, `chunk_overlap_tokens = 0` (opt-in overlap).
See `docs/DECISIONS.md` D5 and `tasks/phase-1a-chunking-design.md` for the algorithm + research.

```sql
-- Package macros are called qualified with the package name (dbt convention, like dbt_utils.*).
{{ dbt_context_engineering.chunk(
    relation         = ref('stg_gong__transcripts'),
    id_column        = 'utterance_id',   -- lineage -> source_rows
    order_column     = 'turn_index',
    text_column      = 'utterance_text',
    partition_column = 'call_id',        -- chunks never span a call
    label_column     = 'speaker'         -- prefixes "speaker: text" in chunk_text
) }}
```

### Splitting long text (`split_sentences`) — layer-1 staging

`chunk` *packs* pre-split units; it does not *split* a blob. For documents that arrive as one
big text, `split_sentences` is the staging step that turns one text row into one row per
sentence (`sentence_id, document_id, sentence_index, sentence_text`), which you then feed to
`chunk` (unit = sentence). Deterministic, zero AI. Boundary rule is naive (`. ! ?`) and
over-splits abbreviations — for prose that needs better boundaries, split with a real tokenizer
upstream. Transcripts skip this: they already arrive as one row per turn.

```sql
-- documents -> sentences -> token-bounded chunks
{{ dbt_context_engineering.split_sentences(
    relation    = ref('stg__documents'),
    id_column   = 'document_id',   -- lineage -> document_id + sentence_id
    text_column = 'document_text'
) }}
```

Deterministic tests run on **duckdb** (no cloud credentials): `integration_tests/duckdb`. Both
`chunk` and the `split_sentences → chunk` pipeline are also confirmed live on all three
cloud engines.

### Metadata on chunks (`attach_metadata`)

`chunk` and `split_sentences` know nothing about metadata, and stay that way on
purpose. Carrying a source-level field (title, a resolvable citation link, call participants)
onto every chunk row is a `distinct` collapse and a join, plain ANSI SQL with no per-engine
divergence to hide, so it doesn't belong inside a dispatched macro. `attach_metadata` is a
separate, portable macro that composes with their unmodified output as a step after chunking.
`metadata_columns` is semantically agnostic: pass frontmatter fields (customer, participants),
provenance fields (citation_url, recording_url), or any other source-level columns.

```sql
-- documents -> sentences -> token-bounded chunks (both steps unmodified)
{{ dbt_context_engineering.split_sentences(
    relation    = ref('stg__documents'),
    id_column   = 'document_id',
    text_column = 'document_text'
) }}
```

```sql
{{ dbt_context_engineering.chunk(
    relation         = ref('stg_docs_split'),   -- the split_sentences output above
    id_column        = 'sentence_id',
    order_column     = 'sentence_index',
    text_column      = 'sentence_text',
    partition_column = 'document_id'
) }}
```

```sql
-- attach title/citation_url from the ORIGINAL document-level table, joined on document_id
{{ dbt_context_engineering.attach_metadata(
    chunks_relation      = ref('stg_docs_chunks'),   -- the chunk output above
    metadata_relation    = ref('stg__documents'),    -- the document-level table, pre-split
    metadata_key_column  = 'document_id',
    metadata_columns     = ['title', 'citation_url'],
    in_text              = false                     -- default: columns only, not embedded
) }}
```

Same macro, different source. Call-level metadata works identically:

```sql
{{ dbt_context_engineering.attach_metadata(
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
dialect fires. `generate.sql` is the canonical reference — copy its shape. Package macros
are called **package-qualified** (`dbt_context_engineering.*`), like `dbt_utils.*`.

```sql
-- config(pre_hook="{{ dbt_context_engineering.guard_batch(ref('stg_gong__transcripts'), 'segment_text') }}")
select
    call_id,
    {{ dbt_context_engineering.classify(
        input_column  = 'segment_text',
        prompt        = dbt_context_engineering.prompt('EXAMPLE_signal_classify', 'v3'),
        output_schema = dbt_context_engineering.schema_def('EXAMPLE_signal_classify', 'v3')
    ) }} as signal
from {{ ref('stg_gong__transcripts') }}
```

`prompt`/`schema` resolve versioned prompt macros (under `prompts/`) to compile-time
literals; `guard_batch` is the pre-hook circuit breaker so no AI call runs unguarded.
Prompt/guard/chunking logic is validated on duckdb; the AI calls have executed on all three cloud
engines against mock sample data.

### Reading the AI result back — `text` / `field`

The wrappers normalize how you *call* the model, but the raw return **shape** still differs per
engine (Snowflake VARIANT object, Databricks JSON string, BigQuery STRUCT). Two accessors make
the output portable too, so downstream models never branch on the engine:

```sql
-- models/signals.sql — call once (structured), then flatten to typed scalars
with raw as (
    select
        call_id,
        {{ dbt_context_engineering.generate('segment_text',
            dbt_context_engineering.prompt('EXAMPLE_signal_classify','v3'),
            dbt_context_engineering.schema_def('EXAMPLE_signal_classify','v3')) }} as result
    from {{ ref('stg_gong__transcripts') }}
)
select
    call_id,
    {{ dbt_context_engineering.field('result', 'signal') }}   as signal,     -- typed scalar, any engine
    {{ dbt_context_engineering.field('result', 'evidence') }} as evidence
from raw
```

- `text(result)` — plain text of an **unstructured** `generate` (no schema).
- `field(result, 'name', as_type)` — one field out of a **structured** result (`generate`
  with a schema, or `extract`), cast to `as_type` (defaults to string). Flatten with this
  before `conforms_to_schema`. `embed` is the exception — it already returns a usable vector.

## Governed incremental AI model (Phases 2–4 together)

The full pattern — process only new rows, re-embed on a version bump, guard cost, log every run:

```sql
{{ config(
    materialized  = 'incremental',
    unique_key    = 'doc_id',
    pre_hook      = [
        "{{ dbt_context_engineering.guard_batch(ref('stg_docs'), 'body',
            filter=dbt_context_engineering.incremental_delta_predicate('doc_id', var('embedding_model'))) }}",
        "{{ dbt_context_engineering.log_ai_run('embed', model_name=var('embedding_model'),
            relation=ref('stg_docs'), input_column='body',
            filter=dbt_context_engineering.incremental_delta_predicate('doc_id', var('embedding_model'))) }}"
    ]
) }}
{% set delta = dbt_context_engineering.incremental_delta_predicate('doc_id', var('embedding_model')) %}
select
    doc_id,
    '{{ var("embedding_model") }}' as model_version,   -- stamp the pinned version
    {{ dbt_context_engineering.embed('body') }} as embedding
from {{ ref('stg_docs') }}
{% if delta %}where {{ delta }}                            -- delta only; skipped on first build / --full-refresh / version bump
{% endif %}
```

`version_guard` returns True (reprocess all) on first build, `--full-refresh`, or when the
stored `model_version` differs from the pinned one, so a model/embedding-version bump re-embeds
the whole corpus, and the `unique_key` merge replaces the old rows. No custom materialization.

**Guard AND log the delta, not the corpus, from one source of truth.** The body's `where`, the
guard's `filter`, and the log's `filter` must all describe the same batch, or they drift.
`incremental_delta_predicate('doc_id', var('embedding_model'))` returns that predicate once (or
`none` when the whole corpus reruns), so all three agree. Without it: the guard counts the full
source and, once the corpus passes `max_batch_rows`, every incremental run false-trips even for a
few new rows; and the log records the whole corpus every run, so `row_count`/`est_cost` are wrong
by orders of magnitude.

**Both `guard_batch` and `log_ai_run` run as pre-hooks here, not the pre/post split you might
expect.** `log_ai_run` can be used as either a pre-hook or a post-hook when it has no `filter`, or
a `filter` that doesn't reference `this`. But once `filter` is `incremental_delta_predicate(...)`,
which expands to `<unique_key> not in (select <unique_key> from {{ this }})`, hook order stops
being cosmetic: by the time a post-hook fires, this run's merge has already landed the new rows
into `this`, so that same predicate now finds nothing and logs `row_count = 0` for a run that
really processed rows. Running `log_ai_run` as a pre-hook, in the same phase as `guard_batch`,
means both see the same pre-merge state the model body's `where` clause uses. This is why the
example above departs from a plain "guard before, log after" reading: log after the merge is only
safe when nothing you're logging depends on `this`.

Note the pre-hook meters `relation=ref('stg_docs')`, **not** `this`, the token estimate reads
`body`, which exists in the source but not in this model's output (`doc_id, model_version,
embedding`); metering `this` here would error *before* the embed spend, since the incremental
merge hasn't run yet. `this`, `is_incremental()`, and `version_guard()` all resolve inside
pre-/post-hooks, verified on duckdb (`guard_delta`, `logged_filtered`, and `logged_incremental_delta`,
which exercises the exact two-build, real-delta scenario above end to end).

## Retrieval (Phase 5)

`vector_search` ranks a corpus by cosine similarity to a query vector — brute-force over the
embedding **column** by default (no index needed), which is the portable, governed baseline:

```sql
{{ dbt_context_engineering.vector_search(
    relation        = ref('doc_embeddings'),
    embedding_column= 'embedding',
    query_embedding = dbt_context_engineering.embed('search text'),  -- or an array literal
    top_k           = 10,
    id_column       = 'doc_id'
) }}
```

For scale, `create_vector_index` (opt-in, `dbt run-operation` **only** — never a model) builds
the engine's external index/service (Snowflake Cortex Search, BigQuery vector index). These are
separately-billed, stateful objects with idle-serving cost and their own lifecycle — drop them
explicitly. Databricks indexes are created via its Vector Search API, not SQL.

## Knowledge base (Phase 6)

`knowledge_base` unifies multiple pre-embedded sources (tickets, calls, notes, …) into one
mart with a common shape — `source_type, source_id, account_key, text, embedding, ts,
citation_url` — so a single search answers "everything about account X" across systems, with
per-source lineage and a resolvable citation link carried into results. **Register a new
source** by adding one dict to the list; `citation_url` is optional per source (omit it for a
source with no resolvable link and that source's rows get `NULL`):

```sql
-- models/knowledge_base.sql
{{ dbt_context_engineering.knowledge_base([
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
{{ dbt_context_engineering.vector_search(
    relation=ref('knowledge_base'), embedding_column='embedding',
    query_embedding=dbt_context_engineering.embed('renewal risk'),
    id_column='source_id', select_columns=['source_type', 'citation_url'],
    filter="account_key = 'acme'") }}
```

All embeddings must come from the same model (see `version_guard`). A managed hybrid index
over the mart is the opt-in scale step (`create_vector_index`).

## Context evaluation & groundedness (Phase 7)

Context is only useful if it's *trustworthy*. Phase 7 makes AI outputs testable like any other
dbt object — deterministic, no warehouse, no AI spend.

**`grounded`** — a generic (schema.yml) test asserting each row's evidence/quote actually
appears in its source text, so a hallucinated quote fails the build. Normalization (case-fold +
whitespace-collapse) defaults on; set both false for byte-exact grounding.

```yaml
columns:
  - name: evidence
    tests:
      - dbt_context_engineering.grounded:
          source_text_column: segment_text   # ignore_case / normalize_whitespace / allow_empty are optional
```

**`conforms_to_schema`** — a singular-test macro asserting a classify/extract column only holds
values from the enum declared by its `schema`, catching invented labels. The allowed set is
resolved from the same schema macro the wrapper used, so it can never drift into a hand-copied
list. (It's a macro rather than a generic test because resolving a versioned schema by name needs
`schema`'s dynamic dispatch, which only renders in model/singular-test context.)

```sql
-- tests/assert_signals_conform.sql
{{ dbt_context_engineering.conforms_to_schema(ref('signals'), 'signal',
                                                 'EXAMPLE_signal_classify', 'v3') }}
```

**`eval`** — scores predicted labels against a golden/expected column, emitting tidy
`metric, label, value` rows (accuracy + per-label precision/recall). It reads pre-computed
predictions, so it runs with zero AI spend; wrap it in a model and threshold a metric with a test
to gate a prompt/model change. Pass `prompt_version` to stamp rows and snapshot metrics over time
for drift tracking.

```sql
-- models/signal_eval.sql
{{ dbt_context_engineering.eval(ref('signal_predictions'), 'predicted_label', 'expected_label') }}
```

All three are validated end to end on duckdb (both pass and catch directions). The only
per-engine divergence is the containment / whitespace primitives (`contains`,
`collapse_ws`), isolated behind dispatch — see `docs/PARITY.md`.

## Macro reference

Every public object in the package. All are called **package-qualified**
(`dbt_context_engineering.<name>(...)`), like `dbt_utils.*`. Args shown with `=` have defaults.

### Prompts & schemas

**`prompt(name, version)`** — resolves the versioned prompt macro
`prompt__<name>__<version>` (under `prompts/`) to a compile-time string literal. Explicit
versions only — no implicit "latest".
```sql
dbt_context_engineering.prompt('EXAMPLE_signal_classify', 'v3')
```

**`schema(name, version)`** — same, for the output JSON schema macro
`schema__<name>__<version>`. The schema's `enum` is the taxonomy; it should include an
evidence/quote field so every extracted fact carries its source text.

**`render_prompt(prompt, input_column)`** — turns a resolved prompt into a portable SQL string
expression, substituting the `{{ input }}` placeholder with the row's input column. Placeholder
matching is whitespace-tolerant (`{{input}}`, `{{ input }}`, `{{  input  }}` all substitute), so a
stray space never silently sends the literal placeholder to the model. A `none` prompt raises a
clear error — `generate`/`classify`/`extract` all need a resolved prompt (the input is injected via
its placeholder). Used internally by every AI wrapper; call it directly only if you're hand-building
a prompt expression.

**`augment_prompt(prompt, output_schema)`** — prepends an explicit "allowed values" block for
each `enum` field in the schema. Used by the **BigQuery** wrappers so the model is constrained even
though BigQuery's `output_schema` can't carry an enum (Snowflake/Databricks enforce it natively).
No-op when there's no enum. You normally don't call this directly.

### AI functions

The four row-level AI operations. Each takes an `input_column` (a column name as a string), a
resolved `prompt`, an optional `output_schema`, and an optional `model` (defaults to the matching
`model_*` var). Each returns a SQL expression you place in a `select`.

**`generate(input_column, prompt, output_schema=none, model=none)`** — free-form generation.
Returns plain text, or a structured object if you pass `output_schema`. The general-purpose one.

**`classify(input_column, prompt=none, output_schema=none, model=none)`** — single-label
classification. `output_schema` is **required**; its `enum` is the label set. Returns the chosen
label as a **scalar string** on all three engines.

**`extract(input_column, prompt=none, output_schema=none, model=none)`** — typed extraction.
`output_schema` is **required** (the extraction contract); returns a structured record with all its
fields. Use it to pull fields *present in the text* (include an `evidence` field for groundedness).

**`embed(input_column, model=none)`** — row-level embedding. Returns a vector column. The model
is pinned via `embedding_model` (a corpus embedded by one model can't be searched by another).

```sql
-- classify (scalar label) + guard + log, the governed pattern
{{ config(
  pre_hook  = "{{ dbt_context_engineering.guard_batch(ref('stg'), 'text') }}",
  post_hook = "{{ dbt_context_engineering.log_ai_run('classify', model_name=var('model_classify'), relation=ref('stg'), input_column='text') }}"
) }}
select id,
  {{ dbt_context_engineering.classify('text',
      dbt_context_engineering.prompt('EXAMPLE_signal_classify','v3'),
      dbt_context_engineering.schema_def('EXAMPLE_signal_classify','v3')) }} as signal
from {{ ref('stg') }}
```

#### generate vs. classify vs. extract — which to use

They overlap when handed the same schema, but the intent differs:

| | `generate` | `classify` | `extract` |
|---|---|---|---|
| Returns | free text, or a structured object | one **scalar label** | a **typed record** (all schema fields) |
| `output_schema` | optional | required (its `enum` = labels) | required (the contract) |
| Native fn (SF / DBX / BQ) | `AI_COMPLETE` / `ai_query` / `AI.GENERATE` | `AI_CLASSIFY` / `ai_classify` / `AI.GENERATE` | `AI_EXTRACT` / `ai_query` / `AI.GENERATE` |
| Intent | may invent/summarize | pick from a closed set | pull what's in the text (grounded) |

Reach for **classify** when you only need the bucket; **extract** when you need the label *plus* a
quote or several typed fields; **generate** for free text (summary, rewrite, answer) or a bespoke
JSON. `generate` + a schema and `extract` overlap (on BigQuery they're the same call); extract
is the "schema is the point / stay grounded" specialization that maps to dedicated extract functions.

### Reading AI output back

The wrappers normalize the *call*; these normalize the *result* (Snowflake VARIANT / Databricks
JSON string / BigQuery STRUCT). `classify` and `embed` already return usable scalars/vectors.

**`text(ai_result)`** — the plain text of an **unstructured** `generate` (no schema).

**`field(ai_result, field, as_type=none)`** — one field out of a **structured** result
(`generate` with a schema, or `extract`), cast to `as_type` (defaults to string). Flatten with
this before `conforms_to_schema`.
```sql
{{ dbt_context_engineering.field('result', 'signal') }} as signal
```

### Chunking

**`chunk(relation, id_column, order_column, text_column, partition_column=none, label_column=none, target_tokens=none, overlap_tokens=none, join_separator='\n')`** — packs ordered atomic *units*
(rows) into token-bounded chunks that never split a unit or cross `partition_column`, carrying each
unit's id into `source_rows` (lineage). Deterministic, no AI. Defaults: `target_tokens=512`,
`overlap_tokens=0`. Output: `chunk_id, partition_key, chunk_seq, source_rows, chunk_text,
n_source_rows, token_estimate`.

**`split_sentences(relation, id_column, text_column)`** — splits one text row into one row per
sentence (`sentence_id, document_id, sentence_index, sentence_text`) to feed `chunk`. Naive
`[.!?]` boundaries (break after every terminator run) — **identical rule on all engines**, so a
corpus splits the same everywhere. For better splitting use a real tokenizer upstream.

### Cost & audit

**`guard_batch(relation, input_column=none, filter=none)`** — **pre-hook** circuit breaker: counts
rows + estimated tokens of the input and **raises before the model runs** if it exceeds
`max_batch_rows` / `max_est_tokens`. No AI call ships without one. On an incremental model pass
`filter` (see `incremental_delta_predicate`) so it counts the delta, not the whole corpus.

**`estimate_tokens(text_expression)`** — a SQL expression estimating tokens (`ceil(len/4)`), no
AI. Shared by the guard and the log.

**`log_ai_run(function_name, model_name=none, relation=none, input_column=none, filter=none)`** —
**post-hook** that appends one row (model, function, row count, est tokens/cost, timestamp,
invocation id) to the `ai_run_log` model. `relation` defaults to `this`; on an incremental model
pass `filter` so it records the delta, not the whole corpus, and set `relation` to the source when
`input_column` isn't carried into the model's output.

**`ai_run_log`** *(model)* — the append-only incremental usage/cost log the post-hook writes to.

### Incremental / versioning

**`version_guard(pinned_version, version_column='model_version')`** → **bool**. Returns `True`
when an incremental model must **reprocess all rows** (first build, `--full-refresh`, the stored
version differs from `pinned_version`, or the target table predates version stamping and has no
`version_column` yet — the adoption case, which reprocesses and stamps rather than erroring); drive
your model's delta `WHERE` with it and pair with a `unique_key` so a version bump re-embeds the
whole corpus.
```sql
{% if not dbt_context_engineering.version_guard(var('embedding_model')) %}
where doc_id not in (select doc_id from {{ this }})
{% endif %}
```

**`incremental_delta_predicate(unique_key, version=none, version_column='model_version')`** → the
delta `WHERE` predicate for an incremental AI model, or `none` when the whole corpus reruns (first
build / `--full-refresh` / version bump). One source of truth so the body's `where`, the
`guard_batch` `filter`, and the `log_ai_run` `filter` describe the **same** batch and can't drift.
Pass `version` for a versioned/embedding model (gates on `version_guard`); omit it to gate on
`is_incremental()`. Resolves `this`/`is_incremental()`/`version_guard()` correctly inside pre-/post-hooks.

### Retrieval & knowledge base

**`vector_search(relation, embedding_column, query_embedding, top_k=10, id_column=none, select_columns=none, filter=none)`** — ranked cosine similarity over an embedding **column**
(brute-force; no index). Returns `[id_column, select_columns..., score]` ordered, `top_k`. `filter`
restricts the candidate set (e.g. account scoping). Ranking has a secondary sort on `id_column` so
rows tied on score (common with near-duplicate chunks) are stable across runs and engines — pass an
`id_column` to get that determinism at the `top_k` boundary.

**`create_vector_index(name, relation, column, attributes=[], warehouse=none, target_lag='1 day', embedding_model=none, distance_type='COSINE', index_type='IVF', storing=[])`** — **opt-in,
`dbt run-operation` ONLY** (never a model). Builds the engine's external, separately-billed index/
service (Snowflake Cortex Search, BigQuery vector index; Databricks is API-created). Drop it
explicitly when done.

**`knowledge_base(sources)`** — unions many pre-embedded source relations into one common-shape
mart (`source_type, source_id, account_key, text, embedding, ts`) with per-source lineage. `sources`
is a list of dicts (`relation, source_type, source_id, account_key, text, embedding, timestamp`);
register a source by adding one dict. `text` and `ts` are cast to a common type so sources with
differing types (e.g. a `DATE` vs a `TIMESTAMP` timestamp column) union cleanly on strict engines
like BigQuery; `embedding` is not cast — all sources must already share one embedding model (and
thus type), which `version_guard` enforces.

### Evaluation & groundedness

**`grounded`** *(generic test)* — attach in `schema.yml` to an evidence column; fails a row whose
quote isn't a substring of `source_text_column` (after optional case-fold / whitespace-collapse).
Args: `source_text_column` (required), `ignore_case=true`, `normalize_whitespace=true`,
`allow_empty=false`.

**`conforms_to_schema(relation, column, schema_name, schema_version, property=none, allow_null=false)`** — a macro for a **singular test**: returns the rows whose `column` value isn't in the
`schema` enum. Point it at a flattened scalar (use `field` first).

**`eval(relation, prediction_column, expected_column, prompt_version=none)`** — scores predictions
vs. a golden column → `metric, label, value` rows (accuracy + per-label precision/recall). No AI.
Threshold a metric with a test to gate a prompt/model change.

### Internal helpers

Part of the surface but rarely called directly — they isolate per-engine divergence or introspect
schemas:

| Macro | Purpose |
|---|---|
| `array_agg(expr, order_expr)` / `string_agg(expr, sep, order_expr)` | dispatched ordered array / string aggregation (the one divergence inside `chunk`) |
| `contains(haystack, needle)` | dispatched substring test (BigQuery `STRPOS` vs ANSI `POSITION … IN`) — backs `grounded` |
| `collapse_ws(expr)` | dispatched trim + whitespace-collapse — backs `norm_text` |
| `norm_text(expr, ignore_case=false, normalize_whitespace=false)` | composes `lower()` + `collapse_ws` for grounding |
| `schema_enum(output_schema, property=none)` | the allowed-value list from a schema (backs conformance) |
| `schema_categories(output_schema)` / `schema_label_field(output_schema)` | the enum values / the enum property name (used by `classify`) |
| `bq_output_schema(json_schema)` | JSON schema → BigQuery `name TYPE` list |
| `bq_model_params(max_output_tokens, thinking_budget)` | BigQuery `model_params` JSON (output cap + thinking budget) |
| `str_literal(s)` | a portable SQL string literal — **dispatched**: newlines as `chr(10)` everywhere, single quotes doubled everywhere, and backslashes doubled on Snowflake/Databricks/BigQuery (where `\` is an escape char) but left literal on duckdb/ANSI. Backs `render_prompt` and `classify`'s enum arrays so arbitrary prompt/label text can't break or corrupt the SQL |
| `require_bq_model()` / `require_databricks_serverless()` | prerequisite checks (BigQuery advisory; Databricks runtime check deferred — currently a no-op) |

## Configuration

All divergent prerequisites are `vars` (see `dbt_project.yml`), visible and documented — never
inferred. Key vars: `model_generate` / `model_classify` / `model_extract` and
`embedding_model` (per-function model names — always explicit); `chunk_target_tokens` /
`chunk_overlap_tokens`; `max_batch_rows` / `max_est_tokens` (guard ceilings);
`max_output_tokens` and `bq_thinking_budget` (output-side cost control — the latter is
BigQuery/Gemini-only, `0` disables billed "thinking"); `cost_per_1k_tokens` (for logged
`est_cost`). BigQuery's `bq_connection` is **optional** (End-User Credentials cover interactive
queries; the `AI.*` functions need no `CREATE MODEL` — see `docs/PARITY.md`).
