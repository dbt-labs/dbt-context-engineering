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
  cost/                    # guard_batch (guard) / estimate_tokens / log_ai_run / complete_ai_run
  audit/                   # ai_run_log_columns_sql / ensure_ai_run_log_exists
  incremental/             # version_guard / incremental_delta_predicate
  embedding/               # content_hash / embedding_dimension / embedding_fn_fingerprint / embedding_logic_hash
  retrieval/               # vector_search
  operations/              # create_vector_index (run-operation only)
  evaluation/              # grounded / conforms_to_schema / eval (+ contains/collapse_ws/norm_text/schema_enum)
models/audit/              # ai_run_log (append-only usage/cost log)
prompts/                   # prompt+schema library — one Jinja macro per name+version (D4)
seeds/                     # synthetic fixtures (no real customer data)
integration_tests/         # per-adapter (cloud) projects + duckdb/ (credential-free deterministic tests)
ci/                        # structure-only CI profiles (placeholder creds) + verify_embedding_logic_hash.py
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

The full pattern processes only new rows, catches a row whose source text changed even when the
model/version didn't, re-embeds on a version bump, guards cost, logs every run, and stamps the
six-column metadata set an embedding needs to be a trustworthy cache entry rather than an opaque
vector (see ADR-0023).

`content_hash` has to be a real column somewhere upstream of the embedding model, not a same-`SELECT`
alias filtered on in the same query (BigQuery won't resolve that) and not something `guard_batch`/
`log_ai_run` can meter unless their `relation` actually carries it. A small staging model is that
column's one home:

```sql
-- models/stg_docs_hashed.sql
{{ config(materialized = 'view') }}

select
    doc_id,
    body,
    {{ dbt_context_engineering.content_hash('body') }} as content_hash
from {{ ref('stg_docs') }}
where body is not null and length(trim(body)) > 0   -- see the null-handling note below
```

```sql
-- models/doc_embeddings.sql
{{ config(
    materialized  = 'incremental',
    unique_key    = 'doc_id',
    pre_hook      = [
        "{{ dbt_context_engineering.guard_batch(ref('stg_docs_hashed'), 'body',
            filter=dbt_context_engineering.incremental_delta_predicate('doc_id',
                dbt_context_engineering.embedding_fn_fingerprint(model=var('embedding_model')),
                'embedding_fn_fingerprint', content_hash_column='content_hash')) }}",
        "{{ dbt_context_engineering.log_ai_run('embed', model_name=var('embedding_model'),
            relation=ref('stg_docs_hashed'), input_column='body',
            filter=dbt_context_engineering.incremental_delta_predicate('doc_id',
                dbt_context_engineering.embedding_fn_fingerprint(model=var('embedding_model')),
                'embedding_fn_fingerprint', content_hash_column='content_hash')) }}"
    ],
    post_hook     = "{{ dbt_context_engineering.complete_ai_run('embed', model_name=var('embedding_model')) }}"
) }}
{% set fingerprint = dbt_context_engineering.embedding_fn_fingerprint(model=var('embedding_model')) %}
{% set delta = dbt_context_engineering.incremental_delta_predicate('doc_id', fingerprint,
    'embedding_fn_fingerprint', content_hash_column='content_hash') %}
select
    doc_id,
    '{{ var("embedding_model") }}'                          as model_version,     -- audit only, see below
    content_hash,
    {{ dbt_context_engineering.embed('body') }}             as embedding,
    {{ dbt_context_engineering.embedding_dimension(dbt_context_engineering.embed('body')) }} as embedding_dimension,
    '{{ fingerprint }}'                                     as embedding_fn_fingerprint,
    '{{ run_started_at }}'                                  as embedded_at,
    '{{ dbt_context_engineering.embedding_logic_hash() }}'  as embedding_logic_hash  -- audit only, see below
from {{ ref('stg_docs_hashed') }}
{% if delta %}where {{ delta }}                            -- delta only; skipped on first build / --full-refresh / fingerprint bump
{% endif %}
```

`version_guard` (via `incremental_delta_predicate`'s `version`/`version_column` args) returns True
(reprocess all) on first build, `--full-refresh`, or when the stored `embedding_fn_fingerprint`
differs from the one just computed, so a model/dimension/provider-parameter bump re-embeds the
whole corpus, and the `unique_key` merge replaces the old rows. No custom materialization, and no
code change to `version_guard`/`incremental_delta_predicate` was needed to point them at the
fingerprint instead of a bare model-version string, both already compare an arbitrary
`(value, column)` pair. `model_version` keeps being stamped anyway, purely for human debugging,
denormalized and redundant with the fingerprint the same way the source doc keeps a plain model
name column even once a real cache key exists. `embedding_logic_hash()` is the same kind of audit
column for a different axis: which build of `embed()`'s own logic produced the row (see the macro
reference below); neither one ever gates reprocessing.

**Guard AND log the delta, not the corpus, from one source of truth.** The body's `where`, the
guard's `filter`, and the log's `filter` must all describe the same batch, or they drift.
`incremental_delta_predicate(...)` returns that predicate once (or `none` when the whole corpus
reruns), so all three agree. Without it: the guard counts the full source and, once the corpus
passes `max_batch_rows`, every incremental run false-trips even for a few new rows; and the log
records the whole corpus every run, so `row_count`/`est_cost` are wrong by orders of magnitude.

**A row whose key already exists but whose source text changed is a gap the key-existence check
alone can't see**, and `version_guard`'s full-corpus reprocess is the wrong tool for a single
changed row. `content_hash_column` closes it: `incremental_delta_predicate` OR's a row-value
comparison via the dispatched `row_value_not_in()` helper onto the key-existence check, not a
correlated subquery. A correlated form (`content_hash != (select ...)` or `not exists (select ...
where t.doc_id = doc_id)`) is a real trap: an unqualified column inside a correlated subquery
resolves to the subquery's *own* same-named column, not the outer row, whenever the inner table
has a column by that name, which it always will here, so both correlated forms return wrong
answers. Row-value `NOT IN` needs no alias or correlation at all, so there's nothing to shadow. A
row whose current hash is null evaluates the whole tuple comparison to null (duckdb) or false
(Snowflake, Databricks), both mean "excluded" for `WHERE`-clause purposes, so `WHERE` excludes it
and the row's last-known-good embedding stays frozen rather than getting nulled or deleted, on
purpose: a source going null could mean "retract this" or "transient load hiccup," and this
package can't know which, so it doesn't guess.

**`row_value_not_in()` is its own dispatched primitive because the row-value comparison itself
diverges per engine.** BigQuery rejects the plain form (`(a, b) not in (select a, b from t)`,
`"Subquery of type IN must have only one output column"`) and needs its subquery's `SELECT` list
wrapped as a single tuple; that wrapped form is in turn rejected by both Snowflake and Databricks.
Isolated in `macros/incremental/row_value_not_in.sql`, the same `array_agg`/`contains`-style
pattern this package already uses everywhere else for per-engine divergence. See ADR-0023 for the
full reasoning.

**The null/empty-text guard in `stg_docs_hashed` above is documentation, not a package macro**,
and it protects a narrower case than it looks like it should. A row whose text goes null *after* a
successful embed needs no guard at all, freshly-computed null `content_hash` compared against a
stored value is null under three-valued logic, so `WHERE` excludes it automatically, the frozen
behavior above. What the guard actually protects is a row that's *never* been embedded with
currently-null text: the key-existence check is true regardless of content (`TRUE OR ...` is
`TRUE`), so a brand-new null-text row would otherwise still enter the delta and attempt `embed()`
on null input. `chunk()`/`attach_metadata()` were deliberately not changed to add this, reopening
either is scope past what a single null-text row needs.

**Source-column provenance is documentation too.** `label_column`/`text_column` (`chunk`) and
`metadata_columns`/`in_text` (`attach_metadata`) already exist as literal call-site arguments, so
the information is technically present, just in the source of whichever upstream model built the
chunks, not anywhere a consumer looking at the embeddings table would think to check. Name which
source columns and calls fed `embedding`/`chunk_text` in that column's `.yml` `description`,
surfaced natively through `dbt docs generate`, rather than building anything new.

**Which hook phase `log_ai_run` needs depends on what `relation`/`filter` actually reference, not
on preference.** Three cases:

1. `relation` is an explicit ref() to some OTHER table (a source, not `this`), and `filter` (if
   any) doesn't reference `this`. Either pre-hook or post-hook works; that other table's state
   doesn't depend on THIS model's build.
2. `relation` left at its default (`this`), sizing from the model's OWN output, no `filter`.
   Requires a post-hook. Pre-hook runs before the create/merge, so `this` doesn't exist yet on a
   first build (errors) and holds last run's stale state on later builds either way. Only sound
   on a `table` (or always-fully-rebuilt) materialization, where "the freshly built output" and
   "this run's batch" are the same thing.
3. `filter` derived from `this` (e.g. `incremental_delta_predicate`, which expands to
   `<unique_key> not in (select <unique_key> from {{ this }})`), the delta-scoping pattern on an
   incremental model. Requires a pre-hook. By the time a post-hook fires, this run's merge has
   already landed the new rows into `this`, so that same predicate finds nothing and logs
   `row_count = 0` for a run that really processed rows.

The example above is case 3, so `guard_batch` and `log_ai_run` both run as pre-hooks, in the same
phase as each other and as the model body's own delta `where`, all reading the same pre-merge
state. Never combine case 2 with an incremental model (unfiltered `relation=this` on an
incremental); it's wrong in both phases, not risky in just one. Pre-hook reports last run's
state, missing this run's rows entirely. Post-hook reports the whole cumulative table, every row
ever merged in, not this run's batch.

Note the pre-hook meters `relation=ref('stg_docs_hashed')`, not `this`; the token estimate reads
`body`, which exists in that staging model but not in `doc_embeddings`'s own output (`doc_id,
model_version, content_hash, embedding, embedding_dimension, embedding_fn_fingerprint,
embedded_at, embedding_logic_hash`). `this`, `is_incremental()`, and `version_guard()` all resolve
inside pre-/post-hooks, verified on duckdb (`guard_delta`, `logged_delta`, and
`content_hash_delta`, which exercises the exact two-build, real-content-hash-delta scenario above
end to end, including the row-value `NOT IN` predicate inside `guard_batch`'s own aggregate
cost-estimate query) and mirrored on all three cloud warehouses
(`content_hash_delta_sf`/`_dbx`/`_bq`).

**`ai_run_log` tracks each row's lifecycle in a `completed` boolean.** `false` when `log_ai_run`
inserts it, flipped to `true` once `complete_ai_run`'s post-hook confirms the model finished. If
the model errors before reaching that post-hook, the row simply stays `false`. `complete_ai_run`
is always safe as a post-hook, even when `log_ai_run` runs as a pre-hook per the rule above; its
`UPDATE` is keyed on `invocation_id`/`function_name`/`model_name`, never on `this`. `log_ai_run`
also creates `ai_run_log` itself the first time it fires against a target that doesn't have it
yet, so a `dbt run --select <one_model>` that never selects `ai_run_log` still has somewhere to
write.

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
  post_hook = [
    "{{ dbt_context_engineering.log_ai_run('classify', model_name=var('model_classify'), relation=ref('stg'), input_column='text') }}",
    "{{ dbt_context_engineering.complete_ai_run('classify', model_name=var('model_classify')) }}"
  ]
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

**`log_ai_run(function_name, model_name=none, relation=none, input_column=none, filter=none)`**,
pre-hook or post-hook (see its docstring for the rule on which), appends one row (model, function,
row count, est tokens/cost, timestamp, invocation id, `completed=false`) to the `ai_run_log`
model. `relation` defaults to `this`; on an incremental model pass `filter` so it records the
delta, not the whole corpus, and set `relation` to the source when `input_column` isn't carried
into the model's output. Creates `ai_run_log` itself the first time it fires against a target
that doesn't have it yet.

**`complete_ai_run(function_name, model_name=none)`**, always safe as a post-hook regardless of
where `log_ai_run` runs. Flips the row `log_ai_run` inserted this invocation from `completed=false`
to `true`, matched on `invocation_id`/`function_name`/`model_name`. Pass it the same
`function_name`/`model_name` given to the paired `log_ai_run` call.

**`ai_run_log`** *(model)*, the append-only incremental usage/cost log `log_ai_run` writes to.
Its `completed` column is `false` until `complete_ai_run` confirms the model finished, see above.

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

**`incremental_delta_predicate(unique_key, version=none, version_column='model_version', content_hash_column=none)`**
→ the delta `WHERE` predicate for an incremental AI model, or `none` when the whole corpus reruns
(first build / `--full-refresh` / version bump). One source of truth so the body's `where`, the
`guard_batch` `filter`, and the `log_ai_run` `filter` describe the **same** batch and can't drift.
Pass `version` for a versioned/embedding model (gates on `version_guard`); omit it to gate on
`is_incremental()`. Pass `content_hash_column` to also catch a row whose key already exists and
whose version/fingerprint still matches, but whose *source text changed*, a gap the key-existence
check alone can't see, OR'd on via the dispatched `row_value_not_in()` helper, a row-value
comparison, not a correlated subquery (a correlated form of this predicate returns wrong answers
whenever the same column names appear on both sides, see the governed-incremental-model section
above). Resolves `this`/`is_incremental()`/`version_guard()` correctly inside pre-/post-hooks.

**`row_value_not_in(columns, relation)`** → `(col1, col2, ...) not in (select ... from relation)`,
dispatched because BigQuery needs the subquery's own output wrapped as a single tuple and
Snowflake/Databricks both reject that wrapped form. Backs `incremental_delta_predicate`'s
`content_hash_column` argument; rarely called directly.

### Embedding metadata

The six-column cache-key metadata set for `embed()`, see the governed-incremental-model section
above and ADR-0023: enough to tell whether a stored vector still matches what would be produced
today, and to scope an incident to exactly the rows it touched, without guessing.

**`content_hash(text_expression)`**, SHA-256 of `text_expression` as a lowercase hex string on
every engine. Hash the exact string handed to `embed()`, after chunking, after any
`attach_metadata` `in_text` prepending, not a raw source column, or a change to assembly logic that
doesn't touch the final string goes undetected. Needs to be a real column somewhere upstream of the
embedding model (see the governed-incremental-model section), not a same-`SELECT` alias filtered on
in the same query.

**`embedding_dimension(vector_expression)`**, the length of the vector array, **observed** from
the actual returned value, never the dimension you configured or asked for; a Matryoshka-style
truncation config silently changes the vector while an intent-recorded value would keep agreeing
with your (wrong) config.

**`embedding_fn_fingerprint(model=none, dimension=none, extra=none)`**, a compile-time hash
(plain hex string) of everything that defines the `embed()` **call** besides the input text: model
identity (`model`, defaults to `var('embedding_model')`), a configured dimension/truncation
parameter (`dimension`, always `none` today, `embed()` has no such parameter yet, a
forward-compatible placeholder), and any other vector-affecting provider parameter (`extra`).
Deliberately excludes chunking/preprocessing config (any change to it that actually alters the
text already surfaces as a `content_hash` mismatch) and code identity (see
`embedding_logic_hash()` below). Pass this as `incremental_delta_predicate`'s `version` argument
with `version_column='embedding_fn_fingerprint'` so a model/dimension/provider-parameter bump
re-embeds the whole corpus; `version_guard` needs no code change to do this, it already compares an
arbitrary `(value, column)` pair.

**`embedding_logic_hash()`**, a **generated** literal, a content hash of `embed()`'s call-graph
closure in this package's own source (derived by walking `dbt_context_engineering.<name>(...)`
calls starting from `embed.sql`, not hand-listed, see `ci/verify_embedding_logic_hash.py`),
regenerated and verified by this repo's own CI on every change. Scoped to that closure specifically,
not this package's identity as a whole; a change to unrelated logic elsewhere in the package won't
move this hash. Audit column only, never a fingerprint input, never gates reprocessing, answers
"which build of `embed()`'s own logic produced this row" the rare time that's needed, without
forcing every embedding model to reprocess on every unrelated package release the way folding it
into the fingerprint would. It's a hash of source bytes, not of behavior, so most edits inside the
closure change it without changing any vector already produced; see ADR-0025 for why that's also
the reason it stays an audit column rather than a blocking check.

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
