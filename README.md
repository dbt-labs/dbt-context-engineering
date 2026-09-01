# dbt_context_engineering

A cross-platform dbt package that gives practitioners a reliable, portable toolkit for
**context engineering** (modeling the data that AI agents read) across **Snowflake
(Cortex), Databricks, and BigQuery**.

Analytics engineers became the provider of trusted metrics for their organization. Context is the
next thing they can own. This package produces it: the governed, tested, lineage-backed text and
vectors that AI systems actually read. It is **not** an agent, an MCP server, or a serving layer;
it makes the context those systems consume. Everything ships as ordinary dbt models, macros,
seeds, and tests, reviewed in PRs, enforced by tests, and traceable in the DAG.

This package is dbt Labs' investment in helping our community level up for AI: a new frontier to
push data work toward, and the first design pattern for getting there. We have mapped the
capabilities we believe context engineering requires and started building them out. Some are
validated end to end on all three engines; others ship as beta while we harden them. That map, and
where each piece stands, is in
[The capabilities context engineering requires](#the-capabilities-context-engineering-requires)
below; the reasoning behind every major choice is recorded in the ADRs in [`adr/`](adr/README.md).

It is deliberately unfinished. The patterns that matter most will be the ones practitioners prove
on real corpora, so we are building this in the open and want the community building it with us.

## Why this exists

For a decade we modeled data for one reader: the dashboard. Every model, test, and metric existed
so a person could look at a number and trust it. That work succeeded, and it is still very nearly
all of what our community ships today.

AI brought a new reader. Copilots and agents ask questions a dashboard never could, and they ask
them of text and meaning, not just of aggregates. The warehouses have already invested on their
side of this: every major engine now exposes AI as SQL functions, including embedding functions
that turn text into vectors. What they have not defined is the patterns. The functions exist, but
how to chunk a corpus so retrieval actually works, how to version a prompt, how to keep an
embedding in sync with the text it came from, and how to test whether an answer is grounded are
all still left to each team to reinvent.

Those are modeling problems, and dbt already has the discipline for them: staging models, tests,
docs, one governed DAG. Context engineering is that discipline pointed at the new reader. The
opportunity is for analytics engineers to become the provider of trusted context for their
organization, exactly as they became the provider of trusted metrics.

Those AI surfaces also diverge enough that teams rebuild the same primitives on each platform.
This package normalizes the ~80% that maps cleanly across engines and makes the divergent ~20%
explicit configuration: never inferred, always documented, failing clearly.

## Design pattern: semantic search

Semantic search is the first context engineering design pattern we are putting forward, and the
place to start. It is built, deployed, and validated end to end on Snowflake, Databricks, and
BigQuery: the shortest route from raw text to governed, retrievable context, and the first step we
would hand a team doing context engineering for the first time.

```
        raw text                chunks              labeled chunks           vectors            answers
   (transcripts, docs)   ┌────────────────┐   ┌──────────────────┐   ┌──────────────┐   ┌──────────────┐
        ──────────────▶  │  1. CHUNK      │─▶ │  2. CLASSIFY     │─▶ │  3. EMBED    │─▶ │  4. SEARCH   │
                         └────────────────┘   └──────────────────┘   └──────────────┘   └──────────────┘
                          token-bounded,        typed AI label         governed          ranked cosine
                          lineage-preserving     per chunk              embeddings         retrieval
```

**Chunk → classify → embed → search** is the shape of the pattern. It takes messy source text
(call transcripts, support tickets, docs) and turns it into a searchable, labeled,
lineage-preserving corpus an AI agent can read reliably. Each step is an ordinary dbt model. You
write the pattern once and it runs on any of the three engines.

The steps compose but are independently useful: you can chunk without embedding, and classify
without searching. Together they are the path from "we have a pile of unstructured text" to "an
agent can retrieve the three most relevant, labeled, citable passages about account X."

One pattern is not a practice. Semantic search is the first of what we hope become many context
engineering design patterns, a good share of them sourced from the community as the discipline
gets built. This pattern is the on-ramp, not the whole package: the full set of capabilities
context engineering requires, and how far each is built out, is in
[The capabilities context engineering requires](#the-capabilities-context-engineering-requires)
below.

See the whole path running on a realistic multi-source corpus in the worked example,
[`jaffle-logistics`](https://github.com/dbt-labs/jaffle-logistics).

---

## 1. Chunk

`chunk` packs ordered text units (a transcript turn, a document sentence) into token-bounded
chunks that never split a unit or cross a partition key, carrying each unit's id into `source_rows`
for lineage. Deterministic, zero AI cost. `split_sentences` turns a long document into one row per
sentence to feed `chunk`, and `attach_metadata` joins source-level fields (title, citation link)
onto chunks afterward.

```sql
{{ dbt_context_engineering.chunk(
    relation = ref('stg_gong__transcripts'), id_column = 'utterance_id',
    order_column = 'turn_index', text_column = 'utterance_text',
    partition_column = 'call_id', label_column = 'speaker'
) }}
```

See [ADR-0002](adr/0002-chunking-as-token-bounded-unit-packing.md),
[ADR-0013](adr/0013-attach-metadata-as-a-separate-macro.md), and the worked example for splitting,
metadata, and overlap options.

---

## 2. Classify

`classify` puts a typed label from a closed set (signal, sentiment, risk) on each chunk, which is
what makes the corpus filterable later. Its prompt and output schema are versioned code
(`prompt` / `schema_def`), and every AI call is guarded and logged: `guard_batch` stops a run
before it overspends, `log_ai_run` records the cost. It returns a scalar string on all three
engines.

```sql
select
    chunk_id,
    {{ dbt_context_engineering.classify('chunk_text',
        dbt_context_engineering.prompt('EXAMPLE_signal_classify', 'v3'),
        dbt_context_engineering.schema_def('EXAMPLE_signal_classify', 'v3')) }} as signal
from {{ ref('stg_chunks') }}
```

See [ADR-0001](adr/0001-prompts-and-schemas-as-versioned-macros.md) (prompts as code) and
[ADR-0003](adr/0003-cost-as-a-first-class-output.md) (cost), and the worked example for the
guard/log hooks.

---

## 3. Embed

`embed` turns each chunk into a vector, searchable by meaning. The model is pinned via
`embedding_model` (a corpus embedded by one model can't be searched by another). `embed()` alone
works to get started; for production, a governed incremental pattern re-embeds only what changed
(`content_hash`), re-embeds the whole corpus on a model bump (`version_guard` /
`embedding_fn_fingerprint`), and keeps the guard, log, and model body reading one delta
(`incremental_delta_predicate`).

```sql
select
    chunk_id,
    {{ dbt_context_engineering.embed('chunk_text') }} as embedding
from {{ ref('stg_chunks_classified') }}
```

See [ADR-0004](adr/0004-version-aware-incremental-refresh.md) and
[ADR-0023](adr/0023-embedding-metadata-and-content-hash-delta.md), and the worked example, for the
full governed incremental model.

---

## 4. Search

`vector_search` ranks the corpus by cosine similarity to a query vector, brute-force over the
embedding column by default (no index), filterable by the label from step 2 and carrying the
lineage from step 1. `knowledge_base` unions many pre-embedded sources into one common shape so a
single search answers across systems at once.

```sql
{{ dbt_context_engineering.vector_search(
    relation = ref('chunk_embeddings'), embedding_column = 'embedding',
    query_embedding = dbt_context_engineering.embed('renewal risk'),
    top_k = 10, id_column = 'chunk_id',
    select_columns = ['signal', 'citation_url'], filter = "signal = 'at_risk'"
) }}
```

See [ADR-0005](adr/0005-retrieval-brute-force-default-index-opt-in.md) (retrieval) and
[ADR-0006](adr/0006-knowledge-base-union-to-common-shape.md) (knowledge base), and the worked
example.

---

## Trust: making the context testable

Three deterministic tests make AI output testable like any other dbt object, with no warehouse and
no AI spend: `grounded` fails a row whose evidence quote isn't in its source text,
`conforms_to_schema` fails a label outside its schema's enum, and `eval` scores predictions
against a golden set. See [ADR-0007](adr/0007-context-evaluation-and-groundedness.md).

```yaml
columns:
  - name: evidence
    tests:
      - dbt_context_engineering.grounded:
          source_text_column: chunk_text
```

---

## The capabilities context engineering requires

The semantic search pattern above is deliberately the simple route through. Behind it we mapped
the full set of capabilities we believe context engineering requires, and built each one out. Some
are validated end to end across all three engines; others are implemented but awaiting live
validation; others are a known requirement we are actively developing and treat as beta. The map
is one thing, laid out with their associated maturity.

**Maturity levels**

- **Validated**: built, deterministically tested where applicable, and executed on Snowflake,
  Databricks, and BigQuery (plus duckdb for the deterministic pieces) against sample data.
- **Built**: implemented and structurally verified; live validation at production scale or against
  engine usage/cost tables is deferred (`LIVE-VALIDATION DEFERRED`).
- **Beta**: a required capability we are aware of and actively working on. It ships in the package
  but is not yet fully vetted (larger surface area, more per-engine divergence, or narrower
  validation), so treat it as beta.

| Capability | Delivered by | Maturity |
|---|---|---|
| Coherent, bounded chunking | `chunk`, `split_sentences` | **Validated** |
| Source-level metadata & citations | `attach_metadata` (+ `source_rows` lineage) | **Validated** |
| Prompts & schemas as versioned code | `prompt`, `schema_def`, `render_prompt` | **Validated** |
| Typed classification | `classify` | **Validated** |
| Semantic embedding | `embed` | **Validated** |
| Reproducible / versioned refresh | `version_guard`, `content_hash`, `embedding_fn_fingerprint`, `incremental_delta_predicate` | **Validated** |
| Governed retrieval | `vector_search` | **Validated** |
| Cross-source knowledge base | `knowledge_base` | **Validated** |
| Groundedness & evaluation | `grounded`, `conforms_to_schema`, `eval` | **Validated** |
| Cost governance & audit | `guard_batch`, `log_ai_run`, `complete_ai_run` | **Built** (live cost reconciliation deferred) |
| Free-form generation | `generate` | **Beta** |
| Typed extraction | `extract` | **Beta** |
| Group-level reasoning | `ai_agg`, `guard_agg_batch` | **Beta** |
| Managed / scaled vector index | `create_vector_index` | **Beta** |
| Runtime drift monitoring | `embedding_canary` | **Beta** |

### Capabilities in beta

These are not extras or afterthoughts. They are capabilities we know context engineering needs,
which is why they already ship in the package. They are not yet fully vetted (larger surface area,
more per-engine divergence, or narrower validation than the semantic search pattern), so treat
them as beta:
use them, and expect the edges to move as we and the community harden them.

- **`generate`** / **`extract`**: the other two row-level AI operations. `generate` is free-form
  generation (plain text or a structured object); `extract` pulls a typed record of fields present
  in the text. `classify` (part of the semantic search pattern) covers the closed-set-label case;
  reach for these when you need free text or a multi-field typed extraction. See
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

## Direction and contributing

We built this in the open and intend to keep developing it that way, in close collaboration with
the **dbt community**. The semantic search pattern is validated across the three warehouses; the
beta capabilities above are a known part of the discipline that we are actively hardening. The
intent is that practitioners on Snowflake, Databricks, and BigQuery run it on real corpora, tell
us where it breaks, contribute the design patterns they have had to rebuild by hand, and help
decide what graduates from beta into the validated core.

[`jaffle-logistics`](https://github.com/dbt-labs/jaffle-logistics) is the reference project we
develop alongside the package: a fictional logistics company whose data is scattered across
roughly eight disconnected systems, run through the semantic search pattern into one governed,
searchable knowledge base. It is where we prove patterns on a realistic multi-source corpus.
Issues, PRs, and pattern proposals are all welcome.

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

### Primary path (validated)

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

### Beta (required capabilities, in progress)

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
Credentials cover interactive queries; the `AI.*` functions need no `CREATE MODEL`). The beta
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
