# dbt_context_engineering

A cross-platform dbt package that gives practitioners a reliable, portable toolkit for **context engineering** (modeling the data that AI agents read) across **Snowflake (Cortex), Databricks, and BigQuery**.

Analytics engineers became the provider of trusted metrics for their organization. This allowed them to define how their business measures success, and keep people accountable and aligned so that progress could be made.

Context for AI is the next frontier they can own. This package introduces new patterns to the broader analytics engineering ecosystem so that analytics engineers can level up and own context, producing governed, tested, lineage-backed text transformations such as vectors and AI inference as transformation techniques. This modeled context is better than raw data, because it encodes logic, meaning, and other improvements while making context simpler, cheaper and easier to retrieve for agents. We define the context engineering patterns in the same way that teams did to produce metrics, building a single source of truth for their organizations. The result is trusted context that can power AI work at scale, with the modularity, governance and capabilities that organizations have come to rely on their data teams for.

It is **not** an agent, an MCP server, or a serving layer; it makes the context those systems consume. Everything ships as ordinary dbt models, macros, seeds, and tests, reviewed in PRs, enforced by tests, and traceable in the DAG.

This package is dbt Labs' investment in helping our community level up for AI: a new frontier to push data work toward, and the first design patterns for getting there. We have mapped the capabilities we believe context engineering requires and started building them out. Some are validated end to end on all three engines; others ship as beta while we harden them. That map, and where each piece stands, is in [The capabilities context engineering requires](#the-capabilities-context-engineering-requires) below; the reasoning behind every major choice is recorded in the ADRs in [`adr/`](adr/README.md).

It is deliberately unfinished. The patterns that matter most will be the ones practitioners prove on real corpora, so we are building this in the open and want the community building it with us.

## Why this exists

For a decade we modeled data for one reader: the dashboard. Every model, test, and metric existed so a person could look at a number and trust it. That work succeeded, and it is still very nearly all of what our community ships today.

But aggregation is a one-way door. A metric is thousands of rows compressed into something a person can read at a glance, and the compression does not run backwards: slicing by dimension re-cuts the same roll-up, it never returns the grain underneath. So every number a dashboard puts on a screen sets off the same three questions — why did it move, which ones, what do we do about it — and the chart cannot answer any of them. Those questions become a ticket in the data team's queue, and the answer arrives next week.

The detail was never deleted. It is sitting in the warehouse already or could easily be ingested into it: the call transcripts, support tickets, CRM notes, contracts, and emails your pipelines have been landing for years or that have been waiting for the AI moment to be needed. Nobody modeled it because there is no bar chart that can express a call transcript, so it stayed below the waterline. The metric made it onto the chart; the story explaining the metric stayed behind in the tables.

AI is the first reader that can actually consume that story, and it is reaching for far more kinds of data than our modeling practices were built to serve, using retrieval techniques the industry is still writing the best practices for. The warehouses have moved: every major engine now exposes AI as SQL functions, including embedding functions that turn text into vectors. What none of them has defined is the patterns. How to chunk a corpus so retrieval actually works, how to version a prompt, how to keep an embedding in sync with the text it came from, and how to test whether an answer is grounded are all still left to each team to reinvent.

Those are modeling problems, and dbt already has the discipline for them: staging models, tests, docs, one governed DAG. Context engineering is that discipline pointed at the new reader.

Someone has to own the governed, trusted context feeding their organization's AI, and that job is currently open. It is also a bigger job than the one before it: more people are putting questions to these systems, far more often, than ever opened even the best-designed dashboard. Aggregates are not wrong and dashboards are not going away. The move is to keep modeling — building the marts that model detail back down into context alongside the ones that roll it up into metrics.

Those AI surfaces also diverge enough that teams rebuild the same primitives on each platform. This package normalizes the ~80% that maps cleanly across engines and makes the divergent ~20% explicit configuration: never inferred, always documented, failing clearly.

## Design pattern: semantic search

Semantic search is the first context engineering design pattern we are putting forward, and the place to start. It is built, deployed, and validated end to end on Snowflake, Databricks, and BigQuery: the shortest route from raw text to governed, retrievable context, and the first step we would hand a team doing context engineering for the first time.

```
        raw text                chunks                  vectors               answers
   (transcripts, docs)   ┌────────────────┐      ┌──────────────┐      ┌──────────────┐
        ──────────────▶  │  1. CHUNK      │ ──▶  │  2. EMBED    │ ──▶  │  3. SEARCH   │
                         └────────────────┘      └──────────────┘      └──────────────┘
                          token-bounded,           governed              ranked cosine
                          lineage-preserving        embeddings            retrieval
```

**Chunk → embed → search** is the shape of the pattern. It takes messy source text (call transcripts, support tickets, docs) and turns it into a searchable, lineage-preserving corpus an AI agent can read. Each step is an ordinary dbt model. You write the pattern once and it runs on any of the three engines.

The steps compose but are independently useful: you can chunk without embedding, and embed without searching. Together they turn a pile of unstructured text into something an agent can answer from, with a citation: why on-time delivery slipped last quarter and which accounts drove it, what the contract actually committed us to, what the internal runbook says about a process nobody has written down twice.

Three steps get you a working corpus. Getting *good* answers out of it takes one more move, which is where [classification](#embedding-buys-recall-classification-buys-precision) comes in — but that is an unlock on top of the pattern, not a prerequisite to it.

One pattern is not a practice. Semantic search is the first of what we hope become many context engineering design patterns, a good share of them sourced from the community as the discipline gets built. This pattern is the on-ramp, not the whole package: the full set of capabilities context engineering requires, and how far each is built out, is in [The capabilities context engineering requires](#the-capabilities-context-engineering-requires) below.

See the whole path running on a realistic multi-source corpus in the worked example, [`jaffle-logistics`](https://github.com/dbt-labs/jaffle-logistics).

---

## 1. Chunk

> Retrieval quality is decided before any AI runs. A chunk that splits a sentence in half, or merges two customers' calls, is not something a better model downstream can rescue.

`chunk` packs ordered text units (a transcript turn, a document sentence) into token-bounded chunks that never split a unit and never cross a partition key, carrying each unit's id into `source_rows` for lineage. Deterministic, zero AI cost. `split_sentences` feeds it one row per sentence; `attach_metadata` joins source-level fields (title, citation link) on afterward.

```sql
{{ dbt_context_engineering.chunk(
    relation = ref('stg_gong__transcripts'), id_column = 'utterance_id',
    order_column = 'turn_index', text_column = 'utterance_text',
    partition_column = 'call_id', label_column = 'speaker'
) }}
```

See [ADR-0002](adr/0002-chunking-as-token-bounded-unit-packing.md), [ADR-0013](adr/0013-attach-metadata-as-a-separate-macro.md), and the worked example for splitting, metadata, and overlap options.

---

## 2. Embed

> An embedding is a derived asset that goes stale the moment its source text or its model changes. Governing that refresh is most of what separates a trusted corpus from a pile of vectors.

`embed` turns each chunk into a vector, searchable by meaning, with the model pinned via `embedding_model` (a corpus embedded by one model cannot be searched by another). `embed()` alone works to get started. For production, the governed pattern re-embeds only what changed (`content_hash`), re-embeds the whole corpus on a model bump (`version_guard` / `embedding_fn_fingerprint`), and keeps the guard, the log, and the model body all reading one delta (`incremental_delta_predicate`).

```sql
select
    chunk_id,
    {{ dbt_context_engineering.embed('chunk_text') }} as embedding
from {{ ref('stg_chunks') }}
```

See [ADR-0004](adr/0004-version-aware-incremental-refresh.md) and [ADR-0023](adr/0023-embedding-metadata-and-content-hash-delta.md), and the worked example, for the full governed incremental model.

---

## 3. Search

> Retrieval is the contract with the agent. A passage earns its place not by being similar, but by being similar, filterable, and traceable — so the agent can cite a source, not just paraphrase one.

`vector_search` ranks the corpus by cosine similarity to a query vector: brute-force over the embedding column by default, no index to manage, carrying the lineage from step 1 and filterable by any column the corpus carries. `knowledge_base` unions many pre-embedded sources into one common shape, so a single search answers across systems at once.

```sql
{{ dbt_context_engineering.vector_search(
    relation = ref('chunk_embeddings'), embedding_column = 'embedding',
    query_embedding = dbt_context_engineering.embed('late deliveries and what is driving them'),
    top_k = 10, id_column = 'chunk_id',
    select_columns = ['citation_url']
) }}
```

See [ADR-0005](adr/0005-retrieval-brute-force-default-index-opt-in.md) (retrieval) and [ADR-0006](adr/0006-knowledge-base-union-to-common-shape.md) (knowledge base), and the worked example.

---

## Embedding buys recall. Classification buys precision.

> Semantic search finds text that means something like your query. That is not the same as finding the text you needed, and on a real corpus the gap between the two is wide enough to see.

The three steps above are the pattern, and they work. But we ran them on a realistic corpus in [`jaffle-logistics`](https://github.com/dbt-labs/jaffle-logistics) — one account's story scattered across eight disconnected systems — and asked plain cosine similarity *"late deliveries and what is driving them."* The highest-scoring chunk for that account was six tokens long:

| rank | chunk | score | what it actually is |
|---|---|---|---|
| 1 | `IR-9001::3` | 0.754 | a trailing fragment: *"Reviewed with dispatch."* |
| 2–3, 5 | `IR-70xx::2` | 0.57–0.66 | unrelated incidents' boilerplate remediation lines |
| 4, 6, 8–10 | `TKT-2000xx` | 0.55–0.58 | routine *"can you confirm the delivery window"* check-ins |
| 7 | `CT-99021::2` | 0.565 | the one genuinely relevant chunk in the top 10 |

The quarterly business reviews that actually document the root cause never made the top 10. The reason is structural, not a tuning problem: short and formulaic text sits near the center of embedding space, so it scores respectably against almost any query. Recall was fine. Precision was not.

**`classify` is what closed the gap.** One typed label per chunk from a closed business taxonomy — is this an account assessment, a weather disruption, a handling error, routine status — then the same search, filtered to the category the question is actually about. Every row in the top 10 became real account content, in coherent order, with the boilerplate gone.

```sql
select
    chunk_id,
    {{ dbt_context_engineering.classify('chunk_text',
        dbt_context_engineering.prompt('signal_classify', 'v3'),
        dbt_context_engineering.schema_def('signal_classify', 'v3')) }} as classification
from {{ ref('stg_chunks') }}
```

The label is a filter on `vector_search`, so retrieval narrows to the right category before ranking. Its prompt and schema are versioned macros, so changing a taxonomy is a reviewable diff rather than a silent edit, and every call is guarded and logged like any other AI call.

Two honest limits, both of which we hit. That taxonomy was designed for the questions those demos ask, and a taxonomy that generalizes to questions nobody designed it for is unsolved work. And `classify` has no cache metadata the way `embed` does, so a rebuild relabels the whole corpus and the same text can land in a different category between runs. Filtering by category removes the wrong categories; it does not guarantee the best chunk within a category wins.

This is why classification is an unlock rather than a fourth step. You can run the pattern without it, and what you learn by doing so is exactly why you will want it. The full ranked output for both queries, raw and filtered, is in the worked example's [comparison write-up](https://github.com/dbt-labs/jaffle-logistics).

See [ADR-0001](adr/0001-prompts-and-schemas-as-versioned-macros.md) (prompts as code) and [ADR-0003](adr/0003-cost-as-a-first-class-output.md) (cost).

---

## Trust: making context testable

> Trusted metrics earned their trust from tests. Context has to earn it the same way, and asking a model to grade another model is not a test: it is a second opinion, billed by the token.

Three deterministic tests make AI output testable like any other dbt object, with no warehouse and no AI spend: `grounded` fails a row whose evidence quote isn't in its source text, `conforms_to_schema` fails a label outside its schema's enum, and `eval` scores predictions against a golden set. They run in CI, on every PR, like any other dbt test. See [ADR-0007](adr/0007-context-evaluation-and-groundedness.md).

```yaml
columns:
  - name: evidence
    tests:
      - dbt_context_engineering.grounded:
          source_text_column: chunk_text
```

---

## The capabilities context engineering requires

Semantic search is deliberately the simple route through. Behind it we mapped the capabilities we believe the practice requires and built each one out, though not all to the same depth. The map below is the honest version: what a team needs, what delivers it, and how far we have taken it.

**Maturity levels**

- **Validated**: built, deterministically tested where applicable, and executed on Snowflake, Databricks, and BigQuery (plus duckdb for the deterministic pieces) against sample data.
- **Built**: implemented and structurally verified; live validation at production scale or against engine usage/cost tables is deferred (`LIVE-VALIDATION DEFERRED`).
- **Beta**: a required capability we are aware of and actively working on. It ships in the package but is not yet fully vetted (larger surface area, more per-engine divergence, or narrower validation), so treat it as beta.

| Capability | What it does | Delivered by | Maturity |
|---|---|---|---|
| Coherent, bounded chunking | Packs whole sentences or speaker turns into token-sized chunks, so meaning is never split | `chunk`, `split_sentences` | **Validated** |
| Source-level metadata & citations | Carries title, link, and source ids onto every chunk, so a hit can cite its origin | `attach_metadata` (+ `source_rows` lineage) | **Validated** |
| Prompts & schemas as versioned code | Pins prompts and schemas as immutable named versions, so an output change is a diff | `prompt`, `schema_def`, `render_prompt` | **Validated** |
| Typed classification | Assigns each row exactly one label from a fixed, schema-defined taxonomy | `classify` | **Validated** |
| Semantic embedding | Turns text into vectors, so texts with similar meaning sit close together | `embed` | **Validated** |
| Reproducible / versioned refresh | Re-embeds only changed rows; a model or config bump reprocesses the whole corpus | `version_guard`, `content_hash`, `embedding_fn_fingerprint`, `incremental_delta_predicate` | **Validated** |
| Governed retrieval | Ranks rows by cosine similarity to a query: exact, portable, no index required | `vector_search` | **Validated** |
| Cross-source knowledge base | Unions sources into one shape, so a single search spans systems and cites origins | `knowledge_base` | **Validated** |
| Groundedness & evaluation | Deterministic tests catching hallucinated quotes, off-taxonomy labels, and accuracy regressions | `grounded`, `conforms_to_schema`, `eval` | **Validated** |
| Cost governance & audit | Stops oversized batches before they run, gates spend behind an opt-in, caps output spend, and logs what each run consumed | `guard_batch`, `ai_functions_enabled`, `allow_full_reembed`, `dev_sample_filter`, `log_ai_run`, `complete_ai_run`, `max_output_tokens` / `bq_thinking_budget` | **Built** (live cost reconciliation deferred) |
| Free-form generation | Produces summaries, rewrites, and open answers when no label or field set fits | `generate` | **Beta** |
| Typed extraction | Pulls facts present in the text into typed fields, each with an evidence quote | `extract` | **Beta** |
| Portable AI output | Reads a structured AI result back as a plain scalar, identically on every engine | `text`, `field` | **Beta** |
| Group-level reasoning | Reasons across every row in a group at once, instead of row by row | `ai_agg`, `guard_agg_batch` | **Beta** |
| Managed / scaled vector index | Opt-in managed index for scale; separately billed, charges while idle, never automatic | `create_vector_index` | **Beta** |
| Runtime drift monitoring | Re-embeds frozen probes each build, catching a provider silently returning different vectors | `embedding_canary` | **Beta** |

### Capabilities in beta

These are not extras or afterthoughts. They are capabilities we know context engineering needs, which is why they already ship. They are simply less proven than semantic search — larger surface area, more per-engine divergence, narrower validation — so use them, and expect the edges to move as we and the community harden them.

- **`generate`** / **`extract`**: the other two row-level AI operations. `generate` is free-form generation (plain text or a structured object); `extract` pulls a typed record of fields present in the text. `classify` (the precision unlock above) covers the closed-set-label case; reach for these when you need free text or a multi-field typed extraction. See [ADR-0010](adr/0010-four-ai-operations.md). Read structured results back portably with `text()` / `field()` ([ADR-0008](adr/0008-normalizing-ai-output.md)).
- **`ai_agg`**: group-level aggregation (summarize a whole transcript, roll up sentiment across an account). Cross-adapter behavior diverges the most here; pair with `guard_agg_batch` on Databricks. See [ADR-0028](adr/0028-add-ai-agg-group-level-aggregation.md).
- **`create_vector_index`**: opt-in, `dbt run-operation` **only** (never a model). Builds the engine's external, separately-billed index/service (Snowflake Cortex Search, BigQuery vector index; Databricks via its Vector Search API) for scale beyond the brute-force default. Stateful, with idle-serving cost, so drop it explicitly. See [ADR-0005](adr/0005-retrieval-brute-force-default-index-opt-in.md).
- **`embedding_canary`**: runtime drift monitor. Re-embeds a small fixed probe set and compares it against a blessed baseline by cosine similarity, catching a provider silently changing a pinned model's behavior. **Disabled by default** (`monitoring: +enabled: false`); it makes real `embed()` calls, so add it only to a scheduled production job. Its baseline seed ships disabled the same way, so turning the monitor on also means setting `seeds: dbt_context_engineering: +enabled: true`, or `dbt build`/`dbt seed` won't have the baseline to compare against. See [ADR-0026](adr/0026-embedding-canary-runtime-drift-monitor.md).

---

## Direction and contributing

A practice does not get defined by one package or one vendor. We have shipped the first design pattern and the capabilities underneath it; what we want back is the patterns you have had to rebuild by hand, the places this breaks on a real corpus, and your read on what should graduate from beta into the validated core.

[`jaffle-logistics`](https://github.com/dbt-labs/jaffle-logistics) is the reference project we develop alongside the package: a fictional logistics company whose data is scattered across roughly eight disconnected systems, run through semantic search into one governed, searchable knowledge base. It is where we prove patterns on a realistic multi-source corpus. Issues, PRs, and pattern proposals are all welcome.

---

## Status & testing

Every capability in the table above is built. The cloud AI calls (`generate`, `classify`, `extract`, `embed`, `vector_search`) have executed successfully on Snowflake, Databricks, and BigQuery against **mock sample data**, and chunking, prompt resolution/rendering, the cost guard, and the AI run log execute **deterministically on duckdb**. Not yet validated: real production data at scale, and cost reconciliation against engine usage tables.

**How to run the tests in each environment, and what to check, is in** [`TESTING.md`](TESTING.md)**. The *why* behind each design choice is recorded as ADRs in** [`adr/`](adr/README.md)**.**

---

## Macro reference

Every public object. All are called **package-qualified** (`dbt_context_engineering.<name>(...)`), like `dbt_utils.*`. Args shown with `=` have defaults.

### Validated

#### Chunking

**`chunk(relation, id_column, order_column, text_column, partition_column=none, label_column=none, target_tokens=none, overlap_tokens=none, join_separator='\n')`**: packs ordered atomic *units* into token-bounded chunks that never split a unit or cross `partition_column`, carrying each unit's id into `source_rows` (lineage). Deterministic, no AI. Output: `chunk_id, partition_key, chunk_seq, source_rows, chunk_text, n_source_rows, token_estimate, exceeds_target, partition_hash`. Also supports `materialized='incremental'`, replacing whole partitions on `partition_key` (never `chunk_id`, since a re-chunk can renumber them); enforcement and per-engine requirements are in [ADR-0029](adr/0029-chunk-partition-level-incremental-and-data-shape-guarantees.md).

**`split_sentences(relation, id_column, text_column)`**: splits one text row into one row per sentence (`sentence_id, document_id, sentence_index, sentence_text`) to feed `chunk`. Naive `[.!?]` boundaries, identical on all engines. For better splitting use a real tokenizer upstream.

**`attach_metadata(chunks_relation, metadata_relation, metadata_key_column, metadata_columns, in_text=false)`**: joins constant-per-key source-level columns onto chunk rows (a `distinct` collapse + join). `in_text=True` also prepends a `"col: value"` block to `chunk_text`.

#### Prompts & schemas

**`prompt(name, version)`**: resolves the versioned prompt macro `prompt__<name>__<version>` to a compile-time string literal. Explicit versions only.

**`schema_def(name, version)`**: same, for the output JSON schema macro `schema__<name>__<version>`. The schema's `enum` is the taxonomy; include an evidence/quote field so every extracted fact carries its source text. (Named `schema_def`, not `schema`, as `schema` is reserved by dbt.)

**`render_prompt(prompt, input_column)`**: turns a resolved prompt into a portable SQL expression, substituting the whitespace-tolerant `{{ input }}` placeholder with the row's input column. Used internally by every AI wrapper.

#### Classify

**`classify(input_column, prompt=none, output_schema=none, model=none)`**: single-label classification. `output_schema` is **required**; its `enum` is the label set. Returns the chosen label as a **scalar string** on all three engines. Native fn: `AI_CLASSIFY` / `ai_classify` / `AI.GENERATE`.

**`embed(input_column, model=none)`**: row-level embedding; returns a vector column. Model pinned via `embedding_model`.

#### Cost & audit

**`guard_batch(relation, input_column=none, filter=none)`**: **pre-hook** circuit breaker: counts rows + estimated tokens and **raises before the model runs** if it exceeds `max_batch_rows` / `max_est_tokens`. No AI call ships without one. Pass `filter` on an incremental model so it counts the delta.

**`estimate_tokens(text_expression)`**: a SQL expression estimating tokens (`ceil(len/4)`), no AI. Shared by the guard and the log.

**`dev_sample_filter(row_limit=none)`**: a portable `qualify row_number() … <= n` clause that caps a model to a random `row_limit` rows (or `var('ai_sample_rows')` if unset). Append it to a model's final `select` while iterating, so nothing is metered or billed against the full corpus by accident.

**`log_ai_run(function_name, model_name=none, relation=none, input_column=none, filter=none)`**: pre- or post-hook (see [ADR-0022](adr/0022-log-ai-run-hook-phase-follows-what-this-means.md) for which one); appends a `'started'` row to `ai_run_log` with the batch's sizing (row count, estimated tokens/cost). Creates `ai_run_log` itself the first time it fires against a target that lacks it.

**`complete_ai_run(function_name, model_name=none)`**: always safe as a post-hook; appends a **separate** `'completed'` row (never an `UPDATE`) once the model finishes, matched back to its `'started'` row on `invocation_id`/`function_name`/`model_name`. Event-sourced rather than a boolean flip, so two concurrent runs never contend for the same row ([ADR-0031](adr/0031-run-completion-as-an-event-sourced-append.md)).

**`ai_run_log`** *(model)*: the append-only, event-sourced usage/cost log `log_ai_run` / `complete_ai_run` write to. `event` is `'started'` or `'completed'`; sizing columns are null on a `'completed'` row.

#### Incremental / versioning (embed)

**`version_guard(pinned_version, version_column='model_version')`** → **bool**: `True` when an incremental model must **reprocess all rows** (first build, `--full-refresh`, stored version differs, or no `version_column` yet). Drive your delta `WHERE` with it and pair with a `unique_key`.

**`incremental_delta_predicate(unique_key, version=none, version_column='model_version', content_hash_column=none)`** → the delta `WHERE` predicate (or `none` when the whole corpus reruns). One source of truth for the body's `where`, the guard's `filter`, and the log's `filter`. Pass `content_hash_column` to also catch a row whose key exists but whose *source text changed*. Not `embed`-specific: the same predicate, bare or with `content_hash_column`, governs an incremental `classify` / `generate` / `extract` / `attach_metadata` / `knowledge_base` model exactly the same way.

**`row_value_not_in(columns, relation)`** → dispatched row-value `NOT IN`; backs `incremental_delta_predicate`'s `content_hash_column`. Rarely called directly.

**`content_hash(text_expression)`**: SHA-256 (lowercase hex) of the exact string handed to `embed()`, after chunking and any `in_text` prepending. Must be a real upstream column.

**`embedding_dimension(vector_expression)`**: the **observed** length of the returned vector, never the configured dimension.

**`embedding_fn_fingerprint(model=none, dimension=none, extra=none)`**: compile-time hash of everything defining the `embed()` call besides input text. Pass as `incremental_delta_predicate`'s `version` with `version_column='embedding_fn_fingerprint'`.

**`embedding_logic_hash()`**: CI-verified content hash of `embed()`'s call-graph closure in this package's source. Audit column only, never gates reprocessing. See [ADR-0025](adr/0025-embedding-logic-hash-as-a-ci-verified-content-hash.md).

#### Search

**`vector_search(relation, embedding_column, query_embedding, top_k=10, id_column=none, select_columns=none, filter=none)`**: ranked cosine similarity over an embedding **column** (brute-force; no index). Returns `[id_column, select_columns..., score]` ordered, `top_k`. Secondary sort on `id_column` for tie stability.

**`knowledge_base(sources)`**: unions many pre-embedded source relations into one common-shape mart (`source_type, source_id, account_key, text, embedding, ts, citation_url, classification`) with per-source lineage. `sources` is a list of dicts; `citation_url` and `classification` are each independently optional per source.

#### Trust

**`grounded`** *(generic test)*: attach in `schema.yml` to an evidence column; fails a row whose quote isn't a substring of `source_text_column`. Args: `source_text_column` (required), `ignore_case=true`, `normalize_whitespace=true`, `allow_empty=false`.

**`conforms_to_schema(relation, column, schema_name, schema_version, property=none, allow_null=false)`**: a macro for a **singular test**: returns rows whose `column` value isn't in the schema enum. Point it at a flattened scalar (use `field` first).

**`no_oversized_chunks`** *(generic test)*: attach in `schema.yml` to `chunk()`'s `exceeds_target` column; fails any row where it's `true`. Opt-in (a data-quality signal about the source corpus, not a package bug), the same way `grounded` is opt-in.

### Beta (required capabilities, in progress)

**`generate(input_column, prompt, output_schema=none, model=none)`**: free-form generation; plain text, or a structured object if you pass `output_schema`.

**`extract(input_column, prompt=none, output_schema=none, model=none)`**: typed extraction; `output_schema` **required**; returns a structured record with all its fields.

**`text(ai_result)`**: plain text of an **unstructured** `generate`.

**`field(ai_result, field, as_type=none)`**: one field out of a **structured** result (`generate` with a schema, or `extract`), cast to `as_type`. Flatten with this before `conforms_to_schema`.

**`ai_agg(input_column, prompt, order_column=none, model=none)`**: group-level aggregation across a `GROUP BY` group. `prompt` is a plain instruction string, not a template. Cross-adapter behavior diverges; pair with `guard_agg_batch` on Databricks.

**`guard_agg_batch(relation, input_column, group_by_column, filter=none)`**: grouped counterpart to `guard_batch` for `ai_agg`; sums estimated tokens per group and raises on `max_agg_group_tokens`.

**`create_vector_index(name, relation, column, attributes=[], warehouse=none, target_lag='1 day', embedding_model=none, distance_type='COSINE', index_type='IVF', storing=[])`**: **opt-in, `dbt run-operation` ONLY**. Builds the engine's external, separately-billed index/service. Drop it explicitly.

**`embedding_canary`** *(model, disabled by default)*: runtime drift monitor; re-embeds a fixed probe set and compares to a blessed baseline by cosine similarity.

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
| `require_ai_functions_enabled(fn_name)` / `require_full_refresh_gate(fn_name)` | prerequisite checks wired into every AI function: the `ai_functions_enabled` spend gate and the `allow_full_reembed` full-refresh gate |

## The dispatch pattern

Every engine-specific macro uses `adapter.dispatch` with per-adapter impls (`__snowflake`, `__databricks`, `__bigquery`), the dbt-utils convention. Users call one macro; the correct dialect fires. A dispatched macro `x` lives in `x.sql` (dispatch call only); real SQL in `x__snowflake.sql`, `x__databricks.sql`, `x__bigquery.sql`. `generate.sql` is the canonical reference; copy its shape.

## Configuration

All divergent prerequisites are `vars` (see `dbt_project.yml`), visible and documented, never inferred. Key vars: `model_generate` / `model_classify` / `model_extract` and `embedding_model` (per-function model names, always explicit); `chunk_target_tokens` / `chunk_overlap_tokens`; `max_batch_rows` / `max_est_tokens` (guard ceilings); `ai_functions_enabled` (default `false`; every AI function raises unless it's `true` for the target); `allow_full_reembed` (no default; required on an AI-backed incremental model's own `full_refresh` config, so a bare `--full-refresh` can't silently re-bill the whole corpus); `ai_sample_rows` (caps a model to a random sample via `dev_sample_filter` while iterating); `max_output_tokens` and `bq_thinking_budget` (output-side cost control; the latter BigQuery/Gemini-only, `0` disables billed "thinking"); `cost_per_1k_tokens` (for logged `est_cost`). BigQuery's `bq_connection` is **optional** (End-User Credentials cover interactive queries; the `AI.*` functions need no `CREATE MODEL`). The beta `embedding_canary` adds `embedding_canary_similarity_threshold` (default `0.999`), `embedding_canary_test_severity` (default `warn`), and, Snowflake only, `embedding_canary_vector_dimension` (required, no default); `monitoring: +enabled: true` turns it on.

## Repo map

```
macros/
  functions/               # generate/classify/extract/embed (adapter.dispatch) + prereq checks
  prompts/                 # prompt / schema_def (macro-library loader, ADR-0001) + render_prompt
  chunking/                # chunk (unit packing, incremental-aware) + split_sentences + no_oversized_chunks + array_agg/string_agg
  metadata/                # attach_metadata (join source-level metadata onto chunks)
  cost/                    # guard_batch / estimate_tokens / dev_sample_filter / log_ai_run / complete_ai_run
  audit/                   # ai_run_log_schema / create_ai_run_log_table
  incremental/             # version_guard / incremental_delta_predicate / row_value_not_in
  embedding/               # content_hash / embedding_dimension / embedding_fn_fingerprint / embedding_logic_hash
  retrieval/               # vector_search
  operations/              # create_vector_index (run-operation only)
  evaluation/              # grounded / conforms_to_schema / eval (+ contains/collapse_ws/norm_text/schema_enum)
models/audit/              # ai_run_log (append-only usage/cost log)
seeds/                     # embedding_canary_baseline only, disabled by default (see monitoring above)
integration_tests/         # per-adapter (cloud) projects + duckdb/ (credential-free deterministic tests); each carries its own seeds/ of synthetic fixtures, not shipped to consumers
ci/                        # structure-only CI profiles (placeholder creds) + verify_embedding_logic_hash.py
```

NOTE: This project is provided as-is, without SLAs.