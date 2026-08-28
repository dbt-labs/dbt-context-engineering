# dbt_context_engineering

A cross-platform dbt package that gives practitioners a reliable, portable toolkit for
**context engineering** (modeling the data that AI agents read) across **Snowflake
(Cortex), Databricks, and BigQuery**.

It is **not** an agent, an MCP server, or a serving layer. It produces the governed context
those systems read. Everything ships as ordinary dbt models, macros, seeds, and tests, reviewed
in PRs, enforced by tests, and traceable in the DAG.

## Why this exists

For a decade we modeled data for one reader: the dashboard. AI added new readers like copilots, agents, and the warehouse's own AI SQL functions, that ask questions a dashboard never could. Answering them reliably is a modeling problem, and dbt already has the discipline for it: staging models, tests, docs, one governed DAG. Context engineering is that discipline pointed at a new reader.

Every major warehouse now exposes AI as SQL functions, but the surfaces diverge enough that teams rebuild the same primitives on each platform. This package normalizes the ~80% that maps cleanly across engines and makes the divergent ~20% explicit configuration: never inferred, always documented, and it fails clearly.

## The pattern this package is built around

The heart of the package, and the part we're focused on, have exercised end to end, and recommend building on today is one pipeline:

```
        raw text                chunks              labeled chunks           vectors            answers
   (transcripts, docs)   ┌────────────────┐   ┌──────────────────┐   ┌──────────────┐   ┌──────────────┐
        ──────────────▶  │  1. CHUNK      │─▶ │  2. CLASSIFY     │─▶ │  3. EMBED    │─▶ │  4. SEARCH   │
                         └────────────────┘   └──────────────────┘   └──────────────┘   └──────────────┘
                          token-bounded,        typed AI label         governed          ranked cosine
                          lineage-preserving     per chunk              embeddings         retrieval
```

**Chunk → classify → embed → search** is the backbone of retrieval-augmented context: it takes
messy source text (call transcripts, support tickets, docs) and turns it into a searchable,
labeled, lineage-preserving corpus an AI agent can read reliably. Each step is an ordinary dbt
model. You write the pattern once and it runs on any of the three engines.

The steps compose but are independently useful. You can chunk without embedding and classify without searching. Together they're the path from "we have a pile of unstructured text" to "an agent can retrieve the three most relevant, labeled, citable passages about account X."

Everything else in the package (see [Beyond the core pattern](#beyond-the-core-pattern-not-fully-vetted)) supports or extends this spine but is **not yet fully vetted, so** treat it as a preview and jumping off point for further exploration.

### See it in action: jaffle-logistics

[`jaffle-logistics`](https://github.com/dbt-labs/jaffle-logistics) is the canonical worked
example of this package in use. It models a fictional logistics company whose data is scattered
across roughly eight disconnected systems (CRM, support tickets, dispatch notes, incident
reports, legal contracts, Slack, call transcripts), and shows where exact-match SQL (joins, regex)
runs out of road, then runs exactly this chunk → classify → embed → search pipeline to fold that
free text into one governed, searchable knowledge base, all without leaving dbt. It builds on
DuckDB (local, free), Snowflake, BigQuery, and Databricks, and the full story with real query
output lives in its docs. Start there to see the package end to end on a realistic multi-source
corpus.

---

## 1. Chunk

`chunk` packs ordered, atomic text **units** (a turn for transcripts, a sentence for documents)
into token-bounded chunks that never split a unit, never cross a partition key, and carry every
unit's id into `source_rows` for lineage. Pure window SQL that is deterministic and involves zero AI cost. Defaults: `chunk_target_tokens = 512`, `chunk_overlap_tokens = 0` (opt-in overlap). See
[ADR-0002](adr/0002-chunking-as-token-bounded-unit-packing.md) for the algorithm and research.

**Why chunk at all?** Embedding models and LLMs have bounded context, and retrieval quality
depends on chunks being coherent (one topic, not half of two). Naively cutting text every N
characters splits sentences and destroys meaning. `chunk` packs whole units up to a token budget and stops, so a chunk is always made of complete turns or sentences, and always knows which source rows it came from.

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

Output columns: `chunk_id, partition_key, chunk_seq, source_rows, chunk_text, n_source_rows, token_estimate`. Every chunk carries its source ids, as with all dbt work, lineage is non-negotiable.

### Splitting long text first (`split_sentences`)

`chunk` *packs* pre-split units; it does not *split* a blob. Transcripts already arrive as one
row per turn, so they feed `chunk` directly. Documents that arrive as one big piece of text need a staging step first: `split_sentences` turns one text row into one row per sentence
(`sentence_id, document_id, sentence_index, sentence_text`), which you then feed to `chunk`
(unit = sentence). Deterministic, zero AI. The boundary rule is naive (`. ! ?`) and identical on
every engine, so a corpus splits the same everywhere; for prose that needs better boundaries,
split with a real tokenizer upstream.

```sql
-- documents -> sentences -> token-bounded chunks
{{ dbt_context_engineering.split_sentences(
    relation    = ref('stg__documents'),
    id_column   = 'document_id',
    text_column = 'document_text'
) }}
```

### Carrying metadata onto chunks (`attach_metadata`)

`chunk` and `split_sentences` know nothing about metadata, on purpose. Carrying a source-level
field (title, a citation link, call participants) onto every chunk is a `distinct` collapse and a join, plain SQL with no per-engine divergence, so it lives in a separate, portable macro that composes with their unmodified output.

```sql
-- attach title/citation_url from the ORIGINAL document-level table, joined on document_id
{{ dbt_context_engineering.attach_metadata(
    chunks_relation      = ref('stg_docs_chunks'),   -- the chunk output
    metadata_relation    = ref('stg__documents'),    -- the document-level table, pre-split
    metadata_key_column  = 'document_id',
    metadata_columns     = ['title', 'citation_url'],
    in_text              = false                      -- default: columns only, not embedded
) }}
```

Each `metadata_columns` value must be constant per key (source-level, not unit-level); the macro
collapses `metadata_relation` with `distinct`, so a key carrying conflicting values fails the
`chunk_id` uniqueness test rather than silently keeping one. Pass `in_text=True` to also prepend
a `"col: value"` block to `chunk_text` so the embedding or LLM sees it (`token_estimate` is
recomputed to match). See [ADR-0013](adr/0013-attach-metadata-as-a-separate-macro.md).

---

## 2. Classify

`classify` puts a **typed AI label** on each chunk, a single value from a closed set (signal type, sentiment, topic, risk category). This is what makes the corpus filterable later: "everything classified `at_risk`," "only `pricing` chunks."

**Prompts and schemas are code.** The label set isn't a magic string buried in SQL, it's a versioned prompt/schema pair under `prompts/`, resolved to a compile-time literal. Prompts are
diffable, PR-reviewed, and explicitly versioned (no implicit "latest"). See
[ADR-0001](adr/0001-prompts-and-schemas-as-versioned-macros.md).

**No AI call ships unguarded.** Every AI operation pairs with `guard_batch` (a pre-hook circuit
breaker that stops a run before it spends past a configured ceiling) and `log_ai_run` (which
appends row count, tokens, and estimated cost to the `ai_run_log`). Cost is a first-class output,
not an afterthought. See [ADR-0003](adr/0003-cost-as-a-first-class-output.md).

```sql
{{ config(
  pre_hook  = "{{ dbt_context_engineering.guard_batch(ref('stg_chunks'), 'chunk_text') }}",
  post_hook = [
    "{{ dbt_context_engineering.log_ai_run('classify', model_name=var('model_classify'), relation=ref('stg_chunks'), input_column='chunk_text') }}",
    "{{ dbt_context_engineering.complete_ai_run('classify', model_name=var('model_classify')) }}"
  ]
) }}
select
    chunk_id,
    {{ dbt_context_engineering.classify(
        input_column  = 'chunk_text',
        prompt        = dbt_context_engineering.prompt('EXAMPLE_signal_classify', 'v3'),
        output_schema = dbt_context_engineering.schema_def('EXAMPLE_signal_classify', 'v3')
    ) }} as signal
from {{ ref('stg_chunks') }}
```

`classify` returns the chosen label as a **scalar string** on all three engines. The divergent return shapes (Snowflake VARIANT, Databricks JSON, BigQuery STRUCT) are normalized behind the wrapper, so downstream models never branch on the engine. The schema's `enum` is the taxonomy;
`conforms_to_schema` (see [Trust](#trust-making-the-context-testable)) can later assert the column
only ever holds values from that enum, catching an invented label.

---

## 3. Embed

`embed` turns each chunk into a vector so it can be searched by meaning rather than keyword. The
model is pinned via the `embedding_model` var. A corpus embedded by one model can't be searched by another, so the model identity is explicit and enforced.

```sql
select
    chunk_id,
    {{ dbt_context_engineering.embed('chunk_text') }} as embedding
from {{ ref('stg_chunks_classified') }}
```

**Embeddings are expensive to recompute, so this is where the package earns its keep as a
production pattern.** A trustworthy embedding table only re-embeds what actually changed, catches
a chunk whose source text changed even when the model didn't, re-embeds the whole corpus on a
model bump, guards cost, logs every run, and stamps enough metadata to tell whether a stored
vector still matches what would be produced today. The package ships a governed incremental
pattern that does all of this with no custom materialization:

- **`content_hash`**: hash the exact string handed to `embed()` so a changed chunk is detected
  even when its key already exists.
- **`version_guard`** / **`embedding_fn_fingerprint`**: a model/dimension/provider-parameter bump
  re-embeds the whole corpus; a `unique_key` merge replaces the old rows.
- **`incremental_delta_predicate`**: one source of truth so the model body's `where`, the
  guard's `filter`, and the log's `filter` all describe the same batch and can't drift.

```sql
-- models/chunk_embeddings.sql  (abridged; see the full worked example in ADR-0023)
{{ config(
    materialized = 'incremental',
    unique_key   = 'chunk_id',
    pre_hook     = [
      "{{ dbt_context_engineering.guard_batch(ref('stg_chunks_hashed'), 'chunk_text',
          filter=dbt_context_engineering.incremental_delta_predicate('chunk_id',
              dbt_context_engineering.embedding_fn_fingerprint(model=var('embedding_model')),
              'embedding_fn_fingerprint', content_hash_column='content_hash')) }}",
      "{{ dbt_context_engineering.log_ai_run('embed', model_name=var('embedding_model'),
          relation=ref('stg_chunks_hashed'), input_column='chunk_text',
          filter=dbt_context_engineering.incremental_delta_predicate('chunk_id',
              dbt_context_engineering.embedding_fn_fingerprint(model=var('embedding_model')),
              'embedding_fn_fingerprint', content_hash_column='content_hash')) }}"
    ],
    post_hook    = "{{ dbt_context_engineering.complete_ai_run('embed', model_name=var('embedding_model')) }}"
) }}
{% set fingerprint = dbt_context_engineering.embedding_fn_fingerprint(model=var('embedding_model')) %}
{% set delta = dbt_context_engineering.incremental_delta_predicate('chunk_id', fingerprint,
    'embedding_fn_fingerprint', content_hash_column='content_hash') %}
select
    chunk_id,
    content_hash,
    {{ dbt_context_engineering.embed('chunk_text') }} as embedding,
    '{{ fingerprint }}'                               as embedding_fn_fingerprint,
    '{{ run_started_at }}'                            as embedded_at
from {{ ref('stg_chunks_hashed') }}
{% if delta %}where {{ delta }}{% endif %}
```

The full mechanism, why `content_hash` needs a real upstream column, the pre-/post-hook rules for
`log_ai_run`, why the delta uses a dispatched row-value `NOT IN` instead of a correlated subquery, and the null-text handling, is documented in [ADR-0004](adr/0004-version-aware-incremental-refresh.md) and [ADR-0023](adr/0023-embedding-metadata-and-content-hash-delta.md) so this README stays readable.
If you're just getting started, `embed()` on its own (no incremental config) works fine; adopt the
governed pattern when recompute cost starts to matter.

---

## 4. Search

`vector_search` ranks the embedded corpus by cosine similarity to a query vector, brute-force over the embedding **column** by default (no index needed), which is the portable, governed
baseline. This is the retrieval step an agent calls to pull the most relevant passages, now
filterable by the classification label from step 2 and carrying the lineage from step 1.

```sql
{{ dbt_context_engineering.vector_search(
    relation         = ref('chunk_embeddings'),
    embedding_column = 'embedding',
    query_embedding  = dbt_context_engineering.embed('renewal risk'),  -- or an array literal
    top_k            = 10,
    id_column        = 'chunk_id',
    select_columns   = ['signal', 'citation_url'],
    filter           = "signal = 'at_risk'"
) }}
```

Ranking has a secondary sort on `id_column`, so rows tied on score (common with near-duplicate
chunks) are stable across runs and engines. See
[ADR-0005](adr/0005-retrieval-brute-force-default-index-opt-in.md).

### Searching across many sources at once (`knowledge_base`)

Real questions span systems: "everything about account X" means tickets *and* calls *and* notes.
`knowledge_base` unions multiple pre-embedded sources into one mart with a common shape
(`source_type, source_id, account_key, text, embedding, ts, citation_url, classification`), so a
single `vector_search` answers across all of them with per-source lineage, a resolvable citation
link, and the `classify()` label carried into results. Register a source by adding one dict:

```sql
-- models/knowledge_base.sql
{{ dbt_context_engineering.knowledge_base([
    {'relation': ref('stg_tickets'), 'source_type': 'ticket',
     'source_id': 'ticket_id', 'account_key': 'account_id',
     'text': 'body', 'embedding': 'embedding', 'timestamp': 'created_at',
     'citation_url': 'ticket_url', 'classification': 'category'},
    {'relation': ref('stg_calls'), 'source_type': 'call',
     'source_id': 'call_id', 'account_key': 'account_id',
     'text': 'transcript', 'embedding': 'embedding', 'timestamp': 'call_time',
     'citation_url': 'call_url'}
]) }}
```

All sources must share one embedding model (`version_guard` enforces it). See
[ADR-0006](adr/0006-knowledge-base-union-to-common-shape.md) and
[ADR-0027](adr/0027-classification-as-a-second-privileged-knowledge-base-column.md).
[`jaffle-logistics`](https://github.com/dbt-labs/jaffle-logistics) builds exactly this: one
`knowledge_base` unioning five independent source chains (legal docs, incident reports, CRM notes,
call transcripts, support tickets) into a single searchable mart.

---

## Trust: making the context testable

Context is only useful if it's *trustworthy*. Three deterministic tests make AI outputs testable like any other dbt object, no warehouse, no AI spend, and round out the core pattern. See [ADR-0007](adr/0007-context-evaluation-and-groundedness.md).

- **`grounded`** *(generic test)*: asserts each row's evidence/quote actually appears in its
  source text, so a hallucinated quote fails the build.
- **`conforms_to_schema`** *(singular-test macro)*: asserts a classify/extract column only holds
  values from the enum its schema declares, catching an invented label. The allowed set is
  resolved from the same schema macro the wrapper used, so it can't drift into a hand-copied list.

```yaml
# schema.yml: grounding a classify/extract evidence column
columns:
  - name: evidence
    tests:
      - dbt_context_engineering.grounded:
          source_text_column: chunk_text
```

---

## This is a seed

This package is the **seed of a larger open-source effort**, not a finished product. The chunk → classify → embed → search spine is the part we're confident in and are focusing on first. Around it there's a wider surface including group-level aggregation, managed vector indexes, runtime drift monitoring, and more AI operations, that is built but **not yet fully vetted**.

We're publishing the vetted core now, in the open, so it can grow the way dbt itself did:
through close collaboration with the **dbt community**. The intent is that practitioners on Snowflake, Databricks, and BigQuery use it on real corpora, tell us where it breaks, contribute the patterns they've had to rebuild by hand, and help decide what graduates from preview into the supported core. Issues, PRs, and pattern proposals are all welcome. This toolkit gets more useful the more the community shapes it. [`jaffle-logistics`](https://github.com/dbt-labs/jaffle-logistics) is the reference project we grow alongside the package, the place we prove new patterns on a realistic multi-source corpus before they graduate.

---

## Beyond the core pattern (not fully vetted)

These pieces are built and exercised on all three engines, but they're **in beta,** larger surface area, more per-engine divergence, or narrower validation. Use them, but expect the edges to move as the community weighs in. They are not part of the focused chunk → classify → embed → search story above.

- **`generate`** / **`extract`**: the other two row-level AI operations. `generate` is free-form
  generation (plain text or a structured object); `extract` pulls a typed record of fields present
  in the text. `classify` (in the core pattern) covers the closed-set-label case; reach for these
  when you need free text or a multi-field typed extraction. See
  [ADR-0010](adr/0010-four-ai-operations.md). Read structured results back portably with
  `text()` / `field()` ([ADR-0008](adr/0008-normalizing-ai-output.md)).
- **`ai_agg`**: group-level aggregation (summarize a whole transcript, roll up sentiment across
  an account). Cross-adapter behavior diverges the most here; pair with `guard_agg_batch` on
  Databricks. See [ADR-0028](adr/0028-add-ai-agg-group-level-aggregation.md).
- **`create_vector_index`**: opt-in, `dbt run-operation` **only** (never a model). Builds the
  engine's external, separately-billed index/service (Snowflake Cortex Search, BigQuery vector
  index; Databricks via its Vector Search API) for scale beyond the brute-force default. Stateful,
  with idle-serving cost, so drop it explicitly. See
  [ADR-0005](adr/0005-retrieval-brute-force-default-index-opt-in.md).
- **`embedding_canary`**: runtime drift monitor. Re-embeds a small fixed probe set and compares
  it against a blessed baseline by cosine similarity, catching a provider silently changing a
  pinned model's behavior. **Disabled by default** (`monitoring: +enabled: false`); it makes real
  `embed()` calls, so add it only to a scheduled production job. See
  [ADR-0026](adr/0026-embedding-canary-runtime-drift-monitor.md).

---

## Status & testing

The full toolkit is built: chunking, AI function wrappers, the prompt/schema library, the cost
guard and run log, the incremental pattern + `version_guard`, retrieval, the knowledge base, and
context evaluation.

Testing posture: the cloud AI calls (`generate`, `classify`, `extract`, `embed`, `vector_search`)
have **executed successfully on all three engines** (Snowflake, Databricks, BigQuery) against
**mock sample data**, alongside **full deterministic execution on duckdb** of chunking, prompt
resolution/rendering, the cost guard, and the AI run log. Not yet validated: execution against
real production data at scale, and cost reconciliation against engine usage tables (built,
`LIVE-VALIDATION DEFERRED`).

**How to run the tests in each environment and what to check is in** [`TESTING.md`](TESTING.md)**. The *why* behind each design choice is recorded as ADRs in** [`adr/`](adr/README.md)**.**

---

## Macro reference

Every public object. All are called **package-qualified** (`dbt_context_engineering.<name>(...)`),
like `dbt_utils.*`. Args shown with `=` have defaults.

### Core pattern

#### Chunking

**`chunk(relation, id_column, order_column, text_column, partition_column=none, label_column=none, target_tokens=none, overlap_tokens=none, join_separator='\n')`**: packs ordered atomic *units*
into token-bounded chunks that never split a unit or cross `partition_column`, carrying each unit's
id into `source_rows` (lineage). Deterministic, no AI. Output: `chunk_id, partition_key, chunk_seq, source_rows, chunk_text, n_source_rows, token_estimate`.

**`split_sentences(relation, id_column, text_column)`**: splits one text row into one row per
sentence (`sentence_id, document_id, sentence_index, sentence_text`) to feed `chunk`. Naive
`[.!?]` boundaries, identical on all engines. For better splitting use a real tokenizer upstream.

**`attach_metadata(chunks_relation, metadata_relation, metadata_key_column, metadata_columns, in_text=false)`**: joins constant-per-key source-level columns onto chunk rows (a `distinct`
collapse + join). `in_text=True` also prepends a `"col: value"` block to `chunk_text`.

#### Prompts & schemas

**`prompt(name, version)`**: resolves the versioned prompt macro `prompt__<name>__<version>` to a
compile-time string literal. Explicit versions only.

**`schema_def(name, version)`**: same, for the output JSON schema macro `schema__<name>__<version>`.
The schema's `enum` is the taxonomy; include an evidence/quote field so every extracted fact
carries its source text. (Named `schema_def`, not `schema`, as `schema` is reserved by dbt.)

**`render_prompt(prompt, input_column)`**: turns a resolved prompt into a portable SQL expression,
substituting the whitespace-tolerant `{{ input }}` placeholder with the row's input column. Used
internally by every AI wrapper.

#### Classify

**`classify(input_column, prompt=none, output_schema=none, model=none)`**: single-label
classification. `output_schema` is **required**; its `enum` is the label set. Returns the chosen
label as a **scalar string** on all three engines. Native fn: `AI_CLASSIFY` / `ai_classify` /
`AI.GENERATE`.

**`embed(input_column, model=none)`**: row-level embedding; returns a vector column. Model pinned
via `embedding_model`.

#### Cost & audit

**`guard_batch(relation, input_column=none, filter=none)`**: **pre-hook** circuit breaker: counts
rows + estimated tokens and **raises before the model runs** if it exceeds `max_batch_rows` /
`max_est_tokens`. No AI call ships without one. Pass `filter` on an incremental model so it counts
the delta.

**`estimate_tokens(text_expression)`**: a SQL expression estimating tokens (`ceil(len/4)`), no AI.
Shared by the guard and the log.

**`log_ai_run(function_name, model_name=none, relation=none, input_column=none, filter=none)`**:
pre- or post-hook (see [ADR-0022](adr/0022-log-ai-run-hook-phase-follows-what-this-means.md) for
which one); appends one usage/cost row to `ai_run_log` (`completed=false`). Creates `ai_run_log` itself
the first time it fires against a target that lacks it.

**`complete_ai_run(function_name, model_name=none)`**: always safe as a post-hook; flips the row
`log_ai_run` inserted this invocation to `completed=true`, matched on
`invocation_id`/`function_name`/`model_name`.

**`ai_run_log`** *(model)*: the append-only incremental usage/cost log `log_ai_run` writes to.

#### Incremental / versioning (embed)

**`version_guard(pinned_version, version_column='model_version')`** → **bool**: `True` when an
incremental model must **reprocess all rows** (first build, `--full-refresh`, stored version differs,
or no `version_column` yet). Drive your delta `WHERE` with it and pair with a `unique_key`.

**`incremental_delta_predicate(unique_key, version=none, version_column='model_version', content_hash_column=none)`** → the delta `WHERE` predicate (or `none` when the whole corpus reruns).
One source of truth for the body's `where`, the guard's `filter`, and the log's `filter`. Pass
`content_hash_column` to also catch a row whose key exists but whose *source text changed*.

**`row_value_not_in(columns, relation)`** → dispatched row-value `NOT IN`; backs
`incremental_delta_predicate`'s `content_hash_column`. Rarely called directly.

**`content_hash(text_expression)`**: SHA-256 (lowercase hex) of the exact string handed to
`embed()`, after chunking and any `in_text` prepending. Must be a real upstream column.

**`embedding_dimension(vector_expression)`**: the **observed** length of the returned vector,
never the configured dimension.

**`embedding_fn_fingerprint(model=none, dimension=none, extra=none)`**: compile-time hash of
everything defining the `embed()` call besides input text. Pass as `incremental_delta_predicate`'s
`version` with `version_column='embedding_fn_fingerprint'`.

**`embedding_logic_hash()`**: CI-verified content hash of `embed()`'s call-graph closure in this
package's source. Audit column only, never gates reprocessing. See
[ADR-0025](adr/0025-embedding-logic-hash-as-a-ci-verified-content-hash.md).

#### Search

**`vector_search(relation, embedding_column, query_embedding, top_k=10, id_column=none, select_columns=none, filter=none)`**: ranked cosine similarity over an embedding **column**
(brute-force; no index). Returns `[id_column, select_columns..., score]` ordered, `top_k`. Secondary
sort on `id_column` for tie stability.

**`knowledge_base(sources)`**: unions many pre-embedded source relations into one common-shape mart
(`source_type, source_id, account_key, text, embedding, ts, citation_url, classification`) with
per-source lineage. `sources` is a list of dicts; `citation_url` and `classification` are each
independently optional per source.

#### Trust

**`grounded`** *(generic test)*: attach in `schema.yml` to an evidence column; fails a row whose
quote isn't a substring of `source_text_column`. Args: `source_text_column` (required),
`ignore_case=true`, `normalize_whitespace=true`, `allow_empty=false`.

**`conforms_to_schema(relation, column, schema_name, schema_version, property=none, allow_null=false)`**: a macro for a **singular test**: returns rows whose `column` value isn't in the
schema enum. Point it at a flattened scalar (use `field` first).

### Preview (not fully vetted)

**`generate(input_column, prompt, output_schema=none, model=none)`**: free-form generation; plain
text, or a structured object if you pass `output_schema`.

**`extract(input_column, prompt=none, output_schema=none, model=none)`**: typed extraction;
`output_schema` **required**; returns a structured record with all its fields.

**`text(ai_result)`**: plain text of an **unstructured** `generate`.

**`field(ai_result, field, as_type=none)`**: one field out of a **structured** result (`generate`
with a schema, or `extract`), cast to `as_type`. Flatten with this before `conforms_to_schema`.

**`ai_agg(input_column, prompt, order_column=none, model=none)`**: group-level aggregation across a
`GROUP BY` group. `prompt` is a plain instruction string, not a template. Cross-adapter behavior
diverges; pair with `guard_agg_batch` on Databricks.

**`guard_agg_batch(relation, input_column, group_by_column, filter=none)`**: grouped counterpart to
`guard_batch` for `ai_agg`; sums estimated tokens per group and raises on `max_agg_group_tokens`.

**`create_vector_index(name, relation, column, attributes=[], warehouse=none, target_lag='1 day', embedding_model=none, distance_type='COSINE', index_type='IVF', storing=[])`**: **opt-in,
`dbt run-operation` ONLY**. Builds the engine's external, separately-billed index/service. Drop it
explicitly.

**`embedding_canary`** *(model, disabled by default)*: runtime drift monitor; re-embeds a fixed
probe set and compares to a blessed baseline by cosine similarity.

### Internal helpers

Part of the surface but rarely called directly as they isolate per-engine divergence or introspect schemas:

| Macro | Purpose |
| --- | --- |
| `array_agg(expr, order_expr)` / `string_agg(expr, sep, order_expr)` | dispatched ordered array / string aggregation (the divergence inside `chunk`) |
| `contains(haystack, needle)` | dispatched substring test (BigQuery `STRPOS` vs ANSI `POSITION … IN`), backs `grounded` |
| `collapse_ws(expr)` | dispatched trim + whitespace-collapse, backs `norm_text` |
| `norm_text(expr, ignore_case=false, normalize_whitespace=false)` | composes `lower()` + `collapse_ws` for grounding |
| `schema_enum(output_schema, property=none)` | the allowed-value list from a schema (backs conformance) |
| `schema_categories(output_schema)` / `schema_label_field(output_schema)` | the enum values / the enum property name (used by `classify`) |
| `augment_prompt(prompt, output_schema)` | prepends an "allowed values" block per enum field (BigQuery enum enforcement) |
| `bq_output_schema(json_schema)` | JSON schema → BigQuery `name TYPE` list |
| `bq_model_params(max_output_tokens, thinking_budget)` | BigQuery `model_params` JSON |
| `str_literal(s)` | a portable, dispatched SQL string literal (newlines, quotes, backslashes handled per engine) |
| `require_bq_model()` / `require_databricks_serverless()` | prerequisite checks (BigQuery advisory; Databricks deferred) |

## The dispatch pattern

Every engine-specific macro uses `adapter.dispatch` with per-adapter impls (`__snowflake`,
`__databricks`, `__bigquery`), the dbt-utils convention. Users call one macro; the correct dialect
fires. A dispatched macro `x` lives in `x.sql` (dispatch call only); real SQL in `x__snowflake.sql`,
`x__databricks.sql`, `x__bigquery.sql`. `generate.sql` is the canonical reference; copy its shape.

## Configuration

All divergent prerequisites are `vars` (see `dbt_project.yml`), visible and documented, never
inferred. Key vars: `model_generate` / `model_classify` / `model_extract` and `embedding_model`
(per-function model names, always explicit); `chunk_target_tokens` / `chunk_overlap_tokens`;
`max_batch_rows` / `max_est_tokens` (guard ceilings); `max_output_tokens` and `bq_thinking_budget`
(output-side cost control; the latter BigQuery/Gemini-only, `0` disables billed "thinking");
`cost_per_1k_tokens` (for logged `est_cost`). BigQuery's `bq_connection` is **optional** (End-User
Credentials cover interactive queries; the `AI.*` functions need no `CREATE MODEL`). The preview
`embedding_canary` adds `embedding_canary_similarity_threshold` (default `0.999`),
`embedding_canary_test_severity` (default `warn`), and, Snowflake only,
`embedding_canary_vector_dimension` (required, no default); `monitoring: +enabled: true` turns it on.

## Repo map

```
macros/
  functions/               # generate/classify/extract/embed (adapter.dispatch) + prereq checks
  prompts/                 # prompt / schema_def (macro-library loader, ADR-0001) + render_prompt
  chunking/                # chunk (unit packing) + split_sentences (layer-1 splitter) + array_agg/string_agg
  metadata/                # attach_metadata (join source-level metadata onto chunks)
  cost/                    # guard_batch / estimate_tokens / log_ai_run / complete_ai_run
  audit/                   # ai_run_log_columns_sql / ensure_ai_run_log_exists
  incremental/             # version_guard / incremental_delta_predicate / row_value_not_in
  embedding/               # content_hash / embedding_dimension / embedding_fn_fingerprint / embedding_logic_hash
  retrieval/               # vector_search
  operations/              # create_vector_index (run-operation only)
  evaluation/              # grounded / conforms_to_schema / eval (+ contains/collapse_ws/norm_text/schema_enum)
models/audit/              # ai_run_log (append-only usage/cost log)
prompts/                   # prompt+schema library, one Jinja macro per name+version (ADR-0001)
seeds/                     # synthetic fixtures (no real customer data)
integration_tests/         # per-adapter (cloud) projects + duckdb/ (credential-free deterministic tests)
ci/                        # structure-only CI profiles (placeholder creds) + verify_embedding_logic_hash.py
```
