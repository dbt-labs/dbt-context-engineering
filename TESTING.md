# Testing guide — `dbt_context_engineering`

How to run the test suite in each environment, what each run builds, and what to look for in the
results. See `docs/ARCHITECTURE.md` §9 for the design rationale and `CLAUDE.md` for the testing
posture (structure-only for cloud AI; full deterministic execution on duckdb).

---

## 1. The three gates at a glance

| Gate | Where | Needs creds? | What it proves | How it runs |
|---|---|---|---|---|
| **Structure** | all 3 cloud projects | no | every macro/model/test **renders** the right per-dialect SQL (`dbt parse`, no warehouse connection) | CI `structure` job, on every PR |
| **Deterministic** | `integration_tests/duckdb` | no | everything that doesn't need a cloud AI service is **executed and asserted** on a local duckdb | CI `deterministic-tests` job, on every PR; run it locally too |
| **Live battery** | `integration_tests/{snowflake,databricks,bigquery}` | **yes** | the wrappers + evaluation + accessors actually **run on the real warehouse** and return sane results | CI `live-battery` job — **opt-in**, manual `workflow_dispatch` only |

The rule of thumb: **duckdb proves the logic; the live battery proves the dialect + the model
actually works.** A green PR only requires the first two (no credentials). The live battery is how
you validate against a real Snowflake / Databricks / BigQuery.

---

## 2. Running locally on duckdb (credential-free — your main loop)

This is the fast, free, deterministic suite. No warehouse, no AI spend.

```bash
# one-time: install the local engine
pip install dbt-duckdb

# from the repo root
dbt deps  --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb
mkdir -p target   # duckdb writes its file relative to CWD; ensure the dir exists on a clean checkout
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb --full-refresh
```

Expected result: **`Done. PASS=63 WARN=0 ERROR=0 SKIP=0`** (count grows as tests are added).

> ⚠️ **Always pass `--full-refresh`.** `ai_run_log` is an *append-only incremental* model, so a
> second plain `dbt build` appends another log row and `assert_run_log` (which expects exactly one)
> fails. `--full-refresh` resets the log. A "1 error: assert_run_log got 1 result" after a repeat
> run is this, not a real regression.

### Verify the circuit breaker actually trips (credential-free)

The normal build only proves the guard *allows* a normal batch. To prove it *raises* over the
ceiling (the whole point of `guard_batch`), rebuild the guarded model with a tiny ceiling — this
is **expected to FAIL**:

```bash
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select guard_pass --vars '{max_batch_rows: 3}'
# EXPECTED: Compilation Error — "guard_batch: batch exceeds ceiling ... rows=10 (max ... =3)"
```

If that command *succeeds*, the guard is broken. (CI runs exactly this and inverts the exit code —
see the `circuit breaker trips over ceiling` step in `.github/workflows/ci.yml`.)

---

## 3. Running against a real warehouse (the live battery)

This runs the same projects against Snowflake, Databricks, or BigQuery. **It makes real AI calls
and costs real money** (small — the fixtures are ~10 rows; the `generate_text` model is capped
to 2 rows). It also creates real tables.

### 3.1 One-time setup — a profile per warehouse

Add entries to `~/.dbt/profiles.yml` matching the project `profile:` names:

| Project | `profile:` name | adapter |
|---|---|---|
| `integration_tests/snowflake` | `jaffle-mcp-demo` | `dbt-snowflake` |
| `integration_tests/databricks` | `databricks` | `dbt-databricks` |
| `integration_tests/bigquery` | `bigquery` | `dbt-bigquery` |

Install the adapter you need, e.g. `pip install dbt-bigquery`.

### 3.2 Set the model vars

Model/endpoint names are **vars, never inferred** (they differ per account/region). Set them in the
project `dbt_project.yml` or pass `--vars`. Minimum:

```yaml
# generation + classification + extraction model, and the embedding model/endpoint
model_generate: 'gemini-2.5-flash'        # BigQuery example
embedding_model: 'text-embedding-005'     # BigQuery example
# BigQuery only — cap output + disable Gemini's default "thinking" (billed as output tokens!)
bq_thinking_budget: 0
max_output_tokens: 1024
```

Snowflake/Databricks use their own model names (e.g. Snowflake `mistral-large2`,
Databricks `databricks-claude-haiku-4-5` / `databricks-gte-large-en`). See each project's README.

### 3.3 Run it

```bash
# per warehouse (example: bigquery)
dbt deps  --project-dir integration_tests/bigquery
dbt build --project-dir integration_tests/bigquery --full-refresh
```

Or trigger all three in CI: `gh workflow run ci.yml` (the `live-battery` job; needs the repo secret
`DBT_PROFILES_YML` holding all three profiles).

Expected result: all models build and all **13** `assert_*` tests pass. A failure here is meaningful
— it means a wrapper's dialect is wrong for that account, a model returned nothing, or the AI
produced an off-taxonomy / ungrounded result. See §5.

### 3.4 First live run — recommended order

The first time you point this at a warehouse, isolate problems by building in layers instead of one
big `dbt build`:

```bash
P="--project-dir integration_tests/bigquery"   # or snowflake / databricks

# 1) Deterministic first — no AI, proves connectivity + the eval/guard SQL on the real engine.
dbt build $P --full-refresh --select eval_metrics_bq assert_eval_metrics_bq \
  assert_grounded_bq assert_conforms_catches_bq

# 2) One cheap AI call — proves the model var / endpoint / prerequisite are right before spending more.
dbt build $P --select generate_bq assert_wrappers_nonnull_bq

# 3) The rest of the battery.
dbt build $P --full-refresh

# 4) Version guard needs sequential runs (see §4.1).
dbt build $P --select tag:version_guard --vars '{test_version: v1}'
dbt build $P --select tag:version_guard --vars '{test_version: v2}'
```

What a clean warehouse pass looks like: every model `OK`, every test `PASS`, and the run log holds a
`classify` row with `row_count = 10`. Read any failure by its first-column label against the table in
§5. The **most likely first-run issues** are (a) a wrong `model_*` / embedding var for the account,
(b) an unmet prerequisite (Databricks needs a **serverless** warehouse + DBR 18.2+; BigQuery needs the
AI API enabled), and (c) on BigQuery, a null `signal`/`evidence` in `assert_*_conforms_bq` → the STRUCT
field-access assumption needs adjusting (ping me with the row and I'll fix the one line).

---

## 4. What each environment builds

### duckdb (`integration_tests/duckdb`) — deterministic, no AI

| Capability | Models | Asserted by |
|---|---|---|
| Chunking | `chunk_utterances`, `chunk_docs`, `chunk_overlap`, `split_docs` | `assert_expected_boundaries`, `assert_soft_cap`, `assert_lineage_exactly_once`, `assert_overlap_boundaries`, `assert_overlap_coverage`, `assert_sentence_split` + `unique`/`not_null` |
| Prompts | `render_prompt_test`, `augment_test` | `assert_render_prompt`, `assert_augment_prompt` (enum injection) |
| Cost guard | `guard_pass` | `not_null` + the §2 trip check |
| Run log | `logged_model`, `ai_run_log` | `assert_run_log` |
| Run log (incremental delta, multi-run) | `logged_delta` | `assert_logged_delta` via the multi-run CI step (§4.2) |
| Version guard | `versioned` | `assert_versioned` |
| Retrieval | `search_corpus`, `search_results` | `assert_vector_search` |
| Knowledge base | `kb`, `kb_search`, `source_tickets`, `source_calls` | `assert_knowledge_base`, `assert_kb_search` |
| **Evaluation (P7)** | `eval_predictions`, `eval_metrics` | `assert_eval_metrics`, `assert_grounded`, `assert_conforms`, `assert_conforms_catches`, `grounded` generic test |
| **Output accessors** | `flatten_test` | `assert_flatten`, `assert_flatten_conforms` |

### Each cloud project (`_sf` / `_dbx` / `_bq` suffix) — real warehouse

| Capability | Models (LIVE = real AI call) | Asserted by | Tier |
|---|---|---|---|
| Chunking | `chunk_*`, `chunk_docs_*`, `split_docs_*` | build only (logic proven on duckdb) | deterministic |
| Generate | `generate_*` (LIVE, structured) | `assert_wrappers_nonnull_*` | live |
| Classify | `signals_*` (LIVE, now a scalar label) | `assert_wrappers_nonnull_*`, `assert_signals_conform_*` | live |
| Extract | `extract_*` (LIVE), `extract_flat_*` (field flatten + source text) | `assert_wrappers_nonnull_*`, `assert_extract_conforms_*`, `assert_extract_grounded_*` | live |
| Embed + retrieval | `embeddings_*`, `search_*` (LIVE) | `assert_search_*` | live |
| Knowledge base | `kb_*` (union over the embedded fixture) | `assert_kb_*` | live |
| Run log | populated by `signals_*` post-hook (+ `logged_bq`) → `ai_run_log` | `assert_run_log_*` | live |
| Version guard | `versioned_*` (incremental, no AI; tag `version_guard`) | `assert_versioned_*` via the multi-run CI step (§4.1) | deterministic |
| **Evaluation (P7)** | `eval_metrics_*` (no AI) | `assert_eval_metrics_*`, `assert_grounded_*`, `assert_conforms_catches_*` | deterministic |
| **Output accessors** | `flatten_*` (from `generate_*`), `generate_text_*` (LIVE) | `assert_flatten_conforms_*`, `assert_generate_text_*` | live |

### 4.1 The multi-run version-guard step

`version_guard`'s behavior only appears across *sequential* runs, so the single `dbt build`
above can't prove it. Both CI jobs add a step that runs the version model twice — the same thing
you can run by hand:

```bash
# after a normal build (which stamps v1), on duckdb:
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select versioned assert_versioned --vars '{test_version: v1}'   # delta path (no bump)
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select versioned assert_versioned --vars '{test_version: v2}'   # bump -> reprocess ALL
# on a cloud project, select by tag so it spans adapters:
dbt build --project-dir integration_tests/bigquery --select tag:version_guard --vars '{test_version: v2}'
```

`assert_versioned` is parameterized by `test_version`, so it proves each state: at v1-again all
rows stay v1 (delta filter ran, nothing reprocessed); at v2 **every** row flips to v2 (the guard
reprocessed the whole corpus and the `unique_key` merge replaced the old rows). If a bump left any
row at v1, the test returns a `wrong_version` row.

### 4.2 The multi-run log_ai_run delta step

Whether `log_ai_run` measures the real per-run delta, instead of the full corpus or zero, only
appears across *sequential* runs too, for the same reason as §4.1: a single `dbt build` never
produces a partial delta against an already-existing target. This step is what confirmed the
hook-ordering hazard documented in `log_ai_run`'s docstring and in the "Governed incremental AI
model" section above (surfaced independently against a live incremental model; see dbt_gong's
ADR-0006, github.com/fivetran/dbt_gong):

```bash
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb --full-refresh
# ^ ld_phase defaults to 1: a 5-row baseline against the 10-row fixture_utterances seed.
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select logged_delta assert_logged_delta --vars '{ld_phase: 2}'   # real 5-row delta
```

`assert_logged_delta` expects `row_count = 5` on the phase-2 run. `guard_batch` and `log_ai_run`
both run as pre-hooks here (see `logged_delta.sql`); if either moves to a post-hook while still
scoped by a `this`-referencing filter, the phase-2 run logs `row_count = 0` instead, since the
merge has already landed the new rows into `this` by the time a post-hook fires. Confirmed by
temporarily switching `logged_delta` to the post-hook pattern locally: the phase-1 run is
unaffected (first build has no filter to get the timing wrong), but the phase-2 run logs
`row_count = 0` and `assert_logged_delta` fails.

---

## 5. What to look out for in the results

Read failures by capability. "Fail rows only" tests return the offending rows; the row's first
column names the problem (e.g. `wrong_top_hit`, `bad_accuracy`, `extract_null`).

| Test | Passing result | Red flags & how to read them |
|---|---|---|
| `assert_eval_metrics(_*)` | 0 rows | `bad_accuracy` → `eval` math or `type_float` cast wrong on this engine. `bad_shape` → the full-outer-join label set changed. Metrics are exact (0.75 / 1.0 / 0.5) — any drift is a real bug, **not** float noise. |
| `assert_grounded(_*)`, `grounded` generic | 0 rows | A returned row = a quote that is **not** a substring of its source after case/whitespace normalization → `contains`/`collapse_ws`/`norm_text` mis-rendered for this dialect (e.g. BigQuery raw-string regex, Snowflake's 4th-arg gotcha). |
| `assert_conforms_catches(_*)` | 0 rows | `schema_enum` failed to resolve the taxonomy, or `IN (...)` list built wrong. |
| `assert_search_*` (LIVE) | 0 rows | `wrong_count` ≠ 3 → `top_k`/`VECTOR_SEARCH` wiring off (watch **BigQuery's** divergent table-function path). `not_descending` → ordering/score sign wrong (BigQuery uses `1 - distance`). `score_out_of_range` → not cosine. `wrong_top_hit` → the near-identical utterance didn't rank #1 → **embedding quality / wrong embedding model**, or query embedded with a different model than the corpus. |
| `assert_flatten_conforms_*` (LIVE) | 0 rows | A row = the flattened `signal` is null or off-taxonomy. Null → `field` path wrong for this engine's output shape (VARIANT `:` / STRUCT `.` / JSON `get_json_object`). Off-taxonomy value → the model ignored the schema (most likely on **BigQuery**, where the enum is prompt-constrained only, not schema-enforced). |
| `assert_generate_text_*` (LIVE) | 0 rows | Empty/null text → `text` didn't extract the payload — watch **BigQuery's** `(...).result` struct access. |
| `assert_wrappers_nonnull_*` (LIVE) | 0 rows | `<wrapper>_null` → that wrapper returned nothing on this account (bad endpoint/model var, content filter, unsupported warehouse tier). Cross-check the model var and the prerequisite (Databricks serverless / DBR 18.2+). |
| `assert_signals_conform_*` (LIVE) | 0 rows | A row = `classify`'s normalized scalar label is null or off-taxonomy. Null → the per-engine unwrap is wrong (Snowflake `:labels[0]` / BigQuery `.<field>`) — see §6. Off-taxonomy → the model ignored the label set. |
| `assert_extract_conforms_*` (LIVE) | 0 rows | A row = the flattened extract `signal` is null or off-taxonomy. Null → the `field` path is wrong for this engine's extract shape (Snowflake's `:response` envelope is unwrapped in the wrapper; if BigQuery returns null, its STRUCT field access is wrong). |
| `assert_extract_grounded_*` (LIVE, behavioral) | 0 rows | A row = the model returned an evidence quote that is **not** in the source utterance (a hallucinated quote). This surfaces real extraction quality — it can legitimately fail if the model paraphrases instead of quoting verbatim; investigate the row before assuming a code bug. |
| `assert_kb_*` (LIVE) | 0 rows | `bad_row_count` (≠20) or `missing_source_type` → `knowledge_base`'s union/normalization didn't run as expected on this engine. `null_lineage_or_shape` → a common-shape column (source_id / account_key / embedding / text / source_type) came out null. |
| `assert_run_log_*` (LIVE) | 0 rows | `no_classify_row` → `log_ai_run`'s post-hook INSERT never landed (hook error / ordering). `bad_values` → `row_count`≠10, `est_tokens` null/≤0, or `run_at` null → a cross-engine cast/typing problem in the log INSERT (the classic BigQuery pitfall). |
| `assert_versioned_*` (multi-run) | 0 rows at each version | `wrong_version` after the v2 run → the guard did **not** reprocess on a version bump (delta filter wasn't skipped). `bad_count_or_dupes` → the `unique_key` merge duplicated instead of replacing. |
| `assert_run_log` (duckdb) | 0 rows | If it fails after a **repeat** build, it's the append-only log accumulating — rebuild with `--full-refresh` (see §2). |
| circuit-breaker trip (§2) | **non-zero exit** | If it exits 0, `guard_batch` failed to raise over the ceiling. |

General cloud red flags: an opaque SQL error at build (not a clean `*` compiler error) usually
means an **unmet prerequisite** — Databricks on a Classic/Pro warehouse (needs serverless / DBR
18.2+; the runtime check is a documented no-op today), or a BigQuery project without the AI API
enabled.

---

## 6. Known coverage gaps & deferred items

What remains uncovered or conditional (everything else is now covered on all three warehouses):

- **`create_vector_index`** — run-operation only; creates external, billed objects. **Deliberately
  excluded** from the suite (`LIVE-VALIDATION DEFERRED`).
- **The cloud suite is opt-in.** It runs only on manual `workflow_dispatch` (or locally against a
  profile), never on PR/push. On a normal change, the cloud AI paths are **parsed, not executed** —
  continuous coverage is the duckdb layer; cloud is validated on demand (that's what you're about to do).
- **Some live tests are behavioral, not deterministic gates.** `assert_search_*` (top-hit ranking),
  the `*_conforms_*` checks, and `assert_extract_grounded_*` depend on live model output, so they can
  fail from model nondeterminism rather than a code bug. Read a failing row before assuming a regression.
- **BigQuery classify/extract STRUCT field access is assumed-from-docs** (Snowflake + Databricks
  shapes are confirmed as of 2026-07-29). `assert_signals_conform_bq` / `assert_extract_conforms_bq`
  are the confirmation — a **null** result means the `.<field>` path is wrong for BigQuery.
- **BigQuery Vertex key casing** (`generationConfig`/`thinkingConfig`) — re-confirm on the first live
  BigQuery run.
- **`cost_reconciliation`** — **removed** (2026-07-29); can be re-added later over `ai_run_log`.
- **Some hardening fixes are covered on duckdb only, by design** — they exercise engine-agnostic dbt
  or Jinja, so duckdb is representative and a cloud copy would test the same code path twice:
  the incremental **delta-scoping** of `guard_batch` via `incremental_delta_predicate`
  (pre-hook `this` + `run_query`), **`version_guard` adoption** of a column-less table
  (`get_columns_in_relation`), `vector_search`'s **tiebreaker** (standard `ORDER BY … , id`), and
  `render_prompt`'s **`{{ input }}` spacing tolerance / `prompt=none` error** (pure Jinja). See the
  `guard_delta`, `logged_filtered`, `vg_adopt`, `search_ties_*`, `assert_render_prompt_spacing`
  cases in `integration_tests/duckdb`.

**Closed (were gaps in a prior pass):** classify normalized + asserted; extract flattened, conformance
+ evidence-groundedness asserted; `knowledge_base` union exercised on cloud (`assert_kb_*`);
`log_ai_run` INSERT asserted on cloud (`assert_run_log_*`); `version_guard` delta + bump run on
all three warehouses (§4.1). **Adversarial cloud coverage added 2026-08-10** on all three warehouses
(`LIVE-VALIDATION DEFERRED` until the next live-battery run): `split_sentences` **cross-engine boundary
parity** against a golden set (`assert_split_adversarial_*`, catching the Snowflake divergence #7);
prompt-literal **backslash** + enum-label **apostrophe** escaping executed live via a classify over an
adversarial prompt/schema (`signals_adversarial_*`, #5/#6); and `knowledge_base` **heterogeneous
timestamp** (DATE vs TIMESTAMP) union (`kb_hetero_*`, #8). **`log_ai_run` post-hook timing hazard
found and closed 2026-08-10** (§4.2): `logged_filtered` deliberately used a static filter, by its
own comment, to avoid needing cross-run sequencing, which meant no test ever exercised `log_ai_run`
with a live `incremental_delta_predicate` filter across a genuine incremental delta. `logged_delta`
+ `assert_logged_delta` now do, and confirmed (by temporarily reintroducing the post-hook pattern
locally) that a post-hook placement regresses to `row_count = 0` on the exact scenario this suite
previously couldn't reach. The README's canonical example and `log_ai_run`'s own docstring are
corrected to the pre-hook pattern accordingly.

---

## 7. Quick reference

```bash
# Deterministic (do this constantly)
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb --full-refresh

# Guard trips (expected to FAIL)
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select guard_pass --vars '{max_batch_rows: 3}'

# Structure gate for a cloud dialect (no creds; renders per-dialect SQL)
dbt parse --project-dir integration_tests/bigquery --profiles-dir ci

# Live battery on a real warehouse (needs ~/.dbt profile; costs money)
dbt build --project-dir integration_tests/bigquery --full-refresh
```
