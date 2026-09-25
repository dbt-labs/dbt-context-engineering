# Testing guide — `dbt_context_engineering`

How to run the test suite in each environment, what each run builds, and what to look for in the
results. Testing posture: structure-only for cloud AI, full deterministic execution on duckdb.

---

## 1. The three gates at a glance

| Gate | Where | Needs creds? | What it proves | How it runs |
|---|---|---|---|---|
| **Structure** | `integration_tests/cloud` (all 3 targets) | no | every macro/model/test **renders** the right per-dialect SQL (`dbt parse`, no warehouse connection) | CI `structure` job, on every PR |
| **Deterministic** | `integration_tests/duckdb` | no | everything that doesn't need a cloud AI service is **executed and asserted** on a local duckdb | CI `deterministic-tests` job, on every PR; run it locally too |
| **Live battery** | `integration_tests/cloud` (`--target snowflake/databricks/bigquery`) | **yes** | the wrappers + evaluation + accessors actually **run on the real warehouse** and return sane results | **not in CI**. Run locally by following §4.11's cloud pass |

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

Expected result: **`Done. PASS=206 WARN=0 ERROR=0 SKIP=0`**, verified 2026-09-25. The count grows
as tests are added, so treat the run summary as the source of truth rather than this number.

> ⚠️ **Always pass `--full-refresh`.** Several tests are phase-parameterized and read their
> baseline from a freshly built table. A second plain `dbt build` over an already-populated
> database fails `assert_logged_delta`, `assert_content_hash_delta`, and `assert_chunk_fp_probe`,
> because each reads a 0-row delta instead of its baseline (verified 2026-09-25: `199 total |
> 201 success | 3 error` on Fusion, `PASS=203 ERROR=3 TOTAL=206` on Core, the same three tests).
> This is the repeat-build artifact, not a regression. `--full-refresh` resets them. All three
> duckdb CI jobs pass the flag for this reason rather than relying on a clean runner.

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

### 3.1 One-time setup — one profile, three targets

Add a single `dbt_context_engineering` profile to `~/.dbt/profiles.yml` (matching
`integration_tests/cloud`'s and `integration_tests/duckdb`'s `profile:`), with one target per
warehouse. See `integration_tests/sample.profiles.yml` for a copy-paste starting point with every
required field.

| Target | adapter |
|---|---|
| `snowflake` | `dbt-snowflake` |
| `databricks` | `dbt-databricks` |
| `bigquery` | `dbt-bigquery` |

Install the adapter(s) you need, e.g. `pip install dbt-bigquery`.

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
Databricks `databricks-claude-haiku-4-5` / `databricks-gte-large-en`) — these are set per-target
via `target.type` conditionals in `integration_tests/cloud/dbt_project.yml`. See the project's
README.

### 3.3 Run it

```bash
# per warehouse (example: bigquery)
dbt deps  --project-dir integration_tests/cloud
dbt build --project-dir integration_tests/cloud --target bigquery --full-refresh \
  --vars '{ai_functions_enabled: true}'
```

> **Why every cloud command here carries `--vars '{ai_functions_enabled: true}'`.**
> AI functions are off unless you switch them on (ADR-0030). This project leaves them off on
> purpose, so cloning the repo and running `dbt build` cannot spend money by accident. You switch
> them on one command at a time, which keeps the cost opt-in visible in the command that spends.
> If you forget the flag, the build stops with a compiler error naming the variable. That is
> working as intended, not a bug.
>
> **Do not move this setting into `dbt_project.yml`.** Writing a computed value there, such as
> `"{{ 'true' if target.name == 'prod' else 'false' }}"`, does not do what it looks like it does.
> dbt hands the gate the *text* `"false"` instead of a real false, and the gate treats any
> non-empty text as "on". A line written to allow AI in prod only would allow it everywhere. A
> plain `true` does work, but it re-opens the accident this project is avoiding.

There is no CI job for this. The cloud suite runs locally, against your own profile, by following
§4's cloud pass.

Expected result: all models build and all **44** `assert_*` tests pass, for
`TOTAL=172` per target (verified 2026-09-25 on Snowflake, Databricks, and BigQuery, under both
dbt Core and dbt Fusion). A failure here is meaningful
— it means a wrapper's dialect is wrong for that account, a model returned nothing, or the AI
produced an off-taxonomy / ungrounded result. See §5.

### 3.4 First live run — recommended order

The first time you point this at a warehouse, isolate problems by building in layers instead of one
big `dbt build`:

```bash
P="--project-dir integration_tests/cloud --target bigquery"   # or --target snowflake / databricks

# 1) Deterministic first — no AI, proves connectivity + the eval/guard SQL on the real engine.
#    No $AI needed: nothing here reaches an AI wrapper.
dbt build $P --full-refresh --select eval_metrics assert_eval_metrics \
  assert_grounded assert_conforms_catches

# 2) One cheap AI call — proves the model var / endpoint / prerequisite are right before spending more.
dbt build $P --vars '{ai_functions_enabled: true}' --select generate assert_wrappers_nonnull

# 3) The rest of the battery.
dbt build $P --vars '{ai_functions_enabled: true}' --full-refresh

# 4) Version guard needs sequential runs (see §4.1). No AI wrappers on this path.
dbt build $P --indirect-selection cautious --select tag:version_guard --vars '{test_version: v1}'
dbt build $P --indirect-selection cautious --select tag:version_guard --vars '{test_version: v2}'
```

What a clean warehouse pass looks like: every model `OK`, every test `PASS`, and the run log holds a
`classify` row with `row_count = 10`. Read any failure by its first-column label against the table in
§5. The **most likely first-run issues** are (a) a wrong `model_*` / embedding var for the account,
(b) an unmet prerequisite (Databricks needs **DBR 15.4 LTS or above** and is not available on
Databricks SQL Classic; BigQuery needs the
AI API enabled), and (c) on BigQuery, a null `signal`/`evidence` in `assert_*_conforms` (run with
`--target bigquery`) → the STRUCT field-access assumption needs adjusting (ping me with the row and I'll
fix the one line).

---

## 4. What each environment builds

### duckdb (`integration_tests/duckdb`) — deterministic, no AI

| Capability | Models | Asserted by |
|---|---|---|
| Chunking | `chunk_utterances`, `chunk_docs`, `chunk_overlap`, `split_docs` | `assert_expected_boundaries`, `assert_soft_cap`, `assert_lineage_exactly_once`, `assert_overlap_boundaries`, `assert_overlap_coverage`, `assert_sentence_split` + `unique`/`not_null` |
| Prompts | `render_prompt_test`, `augment_test` | `assert_render_prompt`, `assert_augment_prompt` (enum injection) |
| Cost guard | `guard_pass` | `not_null` + the §2 trip check |
| Cost guard, per-group (`guard_agg_batch`) | `guard_agg_pass` | pass path on every build; the trip path is a CI step at `max_agg_group_tokens: 1` |
| Run log | `logged_model`, `ai_run_log` | `assert_run_log` |
| Run log (incremental delta, multi-run) | `logged_delta` | `assert_logged_delta` via the multi-run CI step (§4.2) |
| Version guard | `versioned` | `assert_versioned` |
| Retrieval | `search_corpus`, `search_results` | `assert_vector_search` |
| Knowledge base | `kb`, `kb_search`, `source_tickets`, `source_calls` | `assert_knowledge_base`, `assert_kb_search` |
| **Evaluation (P7)** | `eval_predictions`, `eval_metrics` | `assert_eval_metrics`, `assert_grounded`, `assert_conforms`, `assert_conforms_catches`, `grounded` generic test |
| **Output accessors** | `flatten_test` | `assert_flatten`, `assert_flatten_conforms` |
| Cost guard (incremental delta, multi-run) | `guard_delta` | `assert_guard_delta` via the CI trip/scope steps (§2) |
| Run log (static filter) | `logged_filtered` | `assert_log_filtered` |
| Run completion (never-completed stays false) | `logged_never_completed` | `assert_never_completed_stays_false` |
| Version guard (adoption of a column-less table) | `vg_adopt` | `assert_vg_adopt` via the multi-run CI step (§4.10) |
| Retrieval (deterministic tiebreak) | `search_ties_corpus`, `search_ties_results` | `assert_vector_search_tiebreak` |
| Embedding metadata (content-hash delta, multi-run) | `content_hash_delta_stg`, `content_hash_delta` | `assert_content_hash_delta` (§4.3) |
| Chunk fingerprint no-op (multi-run) | `chunk_fp_probe_*` chain | `assert_chunk_fp_probe` (§4.9) |
| Chunk partition delta (multi-run) | `chunk_delta`, `chunk_delta_units` | `assert_chunk_delta` (§4.5) |
| Metadata attach + delta | `chunk_metadata_cols`, `chunk_metadata_text`, `chunk_metadata_utterances`, `attach_metadata_delta`, `attach_metadata_delta_meta_stg`, `amd_null_meta*` | `assert_metadata_*`, `assert_attach_metadata_delta` (§4.6), `assert_amd_null_meta` (§4.8) |
| Knowledge base (per-arm delta, multi-run) | `kb_delta`, `kb_delta_*_stg` | `assert_kb_delta` (§4.7) |
| chunk_id orphaning (multi-run, expected failure) | `orphan_chunks`, `orphan_embeddings`, `orphan_amd`, `orphan_kb*` | `relationships` tests (§4.4) |
| **Embedding canary (ADR-0026)** | `embedding_canary` (package model, `monitoring: +enabled: true`) + `embedding_canary_baseline` seed | `assert_embedding_canary_matches_baseline`, severity `warn` here (the duckdb probe compares a fixed stand-in against itself, similarity 1.0) |
| Canary calibration | `canary_calibration` | `assert_canary_calibration_sensitivity` (checks `canary_cosine_similarity` against known similarities) |
| Oversized-chunk test (`no_oversized_chunks`) | `chunk_sized` | the generic test itself, passing at the default target; a CI step re-runs it at `sized_target_tokens: 3` and requires it to fail |
| Dev-mode sampling (`dev_sample_filter`) | `sample_filtered` | `assert_dev_sample_filter`, full corpus on a normal build and a CI step at `ai_sample_rows: 4` |
| Embedding logic hash as an audit column (ADR-0025) | `embedding_canary` | `assert_embedding_logic_hash_lands` + `not_null` |
| Safety-gate raise paths | `probe_ai_gate`, `probe_view_gate`, `probe_full_refresh_gate` (disabled unless their `gate_probe` var selects them) | CI steps only, each matching the gate's error message rather than inverting an exit code |
| `create_vector_index` (no warehouse) | none (run-operation only) | `assert_create_vector_index_ddl` for the Snowflake and BigQuery DDL text, plus the three `probe_create_vector_index_*` raise probes. All CI steps |
| Canary re-bless serializer | `embedding_canary` | `assert_canary_vector_roundtrip`, plus a CI step running `print_embedding_canary` itself |

### `integration_tests/cloud` (`--target snowflake` / `databricks` / `bigquery`) — real warehouse

One shared project, one fixture per capability, run once per target. `model_generate` /
`embedding_model` (and BigQuery's `bq_thinking_budget`) resolve per-target via `target.type`
conditionals in `dbt_project.yml`.

| Capability | Models (LIVE = real AI call) | Asserted by | Tier |
|---|---|---|---|
| Chunking | `chunk_*`, `chunk_docs`, `split_docs` | build only (logic proven on duckdb) | deterministic |
| Generate | `generate` (LIVE, structured) | `assert_wrappers_nonnull` | live |
| Classify | `signals` (LIVE, now a scalar label) | `assert_wrappers_nonnull`, `assert_signals_conform` | live |
| Extract | `extract` (LIVE), `extract_flat` (field flatten + source text) | `assert_wrappers_nonnull`, `assert_extract_conforms`, `assert_extract_grounded` | live |
| Embed + retrieval | `embeddings`, `search` (LIVE) | `assert_search` | live |
| Knowledge base | `kb`, `kb_hetero` (union over the embedded fixture) | `assert_kb`, `assert_kb_hetero` | live |
| Run log | populated by `signals` post-hook → `ai_run_log` | `assert_run_log` | live |
| Version guard | `versioned` (incremental, no AI; tag `version_guard`) | `assert_versioned` via the multi-run CI step (§4.1) | deterministic |
| **Evaluation (P7)** | `eval_metrics` (no AI) | `assert_eval_metrics`, `assert_grounded`, `assert_conforms_catches` | deterministic |
| **Output accessors** | `flatten` (from `generate`), `generate_text` (LIVE) | `assert_flatten_conforms`, `assert_generate_text` | live |
| **Group-level aggregation (ADR-0028)** | `ai_agg` (LIVE), guarded by `guard_agg_batch` in a pre_hook | `assert_ai_agg` | live |
| **Adversarial fixtures** | `adversarial_docs`, `split_adversarial`, `signals_adversarial` (LIVE) | `assert_split_adversarial`, `assert_signals_adversarial` | live + deterministic |
| Embedding metadata (content-hash delta, multi-run) | `content_hash_delta_stg`, `content_hash_delta` | `assert_content_hash_delta` (§4.3) | deterministic |
| Chunk partition delta (multi-run) | `chunk_delta`, `chunk_delta_units` | `assert_chunk_delta` (§4.5) | deterministic |
| Metadata attach + delta | `chunk_metadata_cols`, `chunk_metadata_text`, `chunk_metadata_utterances`, `attach_metadata_delta`, `attach_metadata_delta_meta_stg`, `amd_null_meta*` | `assert_metadata_*`, `assert_attach_metadata_delta` (§4.6), `assert_amd_null_meta` (§4.8) | deterministic |
| Knowledge base (per-arm delta, multi-run) | `kb_delta`, `kb_delta_*_stg` | `assert_kb_delta` (§4.7) | deterministic |
| chunk_id orphaning (multi-run, expected failure) | `orphan_chunks`, `orphan_embeddings`, `orphan_amd`, `orphan_kb*` | `relationships` tests (§4.4) | deterministic |
| **Embedding canary (ADR-0026)** | `embedding_canary` (package model, `monitoring: +enabled: true`) + `embedding_canary_baseline` seed, makes a real `embed()` call | `assert_embedding_canary_matches_baseline`, severity raised to `error` in this project | live |
| Oversized-chunk test (`no_oversized_chunks`) | `chunk_sized` | the generic test itself (parity with duckdb; the trip path is exercised on duckdb only, since the test is engine-independent SQL) | deterministic |
| Dev-mode sampling (`dev_sample_filter`) | `sample_filtered` | `assert_dev_sample_filter`. The point on a warehouse is portability: this is where the emitted `QUALIFY` is proven to parse on Snowflake, Databricks, and BigQuery | deterministic |
| Groundedness generic test (`grounded`) | `extract_flat` | the `grounded` wrapper itself, `allow_empty: true`. `assert_extract_grounded` alongside it checks the same property by calling the internals directly, so the pair covers both the internals and the wrapper a consumer writes | live |
| Embedding logic hash as an audit column (ADR-0025) | `embedding_canary` | `assert_embedding_logic_hash_lands` + `not_null` | deterministic |
| Canary re-bless serializer | `embedding_canary` | `assert_canary_vector_roundtrip`. This is where each engine's own `canary_vector_to_json` is proven to round-trip a real vector, which is what a pasted baseline depends on | live |

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
model" section above:

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

### 4.3 The content-hash delta step (embedding metadata)

Whether a row whose *key* already exists but whose *source text changed* actually gets caught and
re-embedded, rather than silently frozen the way version_guard alone would leave it (see
ADR-0023), also only appears across sequential runs:

```bash
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select content_hash_delta_stg content_hash_delta ai_run_log fixture_utterances --full-refresh
# ^ ch_edit_id defaults to -1: a 10-row baseline, no simulated edit.
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select content_hash_delta_stg content_hash_delta ai_run_log assert_content_hash_delta \
  --vars '{ch_edit_id: 5}'   # simulates utterance_id 5's source text changing
```

`assert_content_hash_delta` expects `row_count = 1` on the phase-2 run (exactly the edited row, not
the whole 10-row corpus and not 0), and that utterance_id 5's `embedded_at` is strictly newer than
every other row's, proving those other 9 rows stayed frozen rather than getting touched. `embedding`
here is a fixed stand-in literal, duckdb has no `embed()` implementation (matches the rest of the
AI surface, LIVE-VALIDATION DEFERRED), so this exercises the metadata/delta mechanism, not a real
vector. `content_hash` is computed in the upstream `content_hash_delta_stg` view, not inline in
`content_hash_delta` itself, both because `guard_batch`/`log_ai_run`'s `relation` needs an actual
`content_hash` column to filter on, and because a same-`SELECT` alias can't be filtered on in the
same query (the BigQuery trap `chunk.sql`'s own comments already document).

The delta condition is a row-value `NOT IN`, not a correlated subquery: a correlated form of this
comparison (an unqualified column inside the subquery resolving to the subquery's own same-named
column instead of the outer row) returns wrong answers whenever the correlated column names match
on both sides, which they always do here. See ADR-0023's Reasoning section for the full case.

`content_hash_delta` and its staging model/tests mirror this exact scenario on all three cloud
targets (same two-build sequence, `--target snowflake/databricks/bigquery --select content_hash_delta_stg
content_hash_delta ai_run_log --vars '{ch_edit_id: 5}'` after a full-refresh baseline), confirming
the same two things a cloud run alone can prove: the row-value `NOT IN` predicate works inside each
engine's real incremental merge, not just in isolation, and BigQuery's merge log line for the
phase-2 build shows exactly 1 row processed, matching the edited row, not the whole 10-row corpus.

### 4.4 The chunk_id orphaning relationships test

`chunk_id` is derived from a cumulative token sum within a partition, so a re-chunk can make a key
that used to exist simply stop being produced, not go null, absent. Nothing in the incremental
merge removes a row whose key is no longer in the source query; that's surfaced with a
`relationships` test rather than fixed (see ADR-0023's Consequences, and ADR-0004's "smallest
mechanism" reasoning for why no deletion logic was added instead):

```bash
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select orphan_chunks orphan_embeddings --full-refresh --vars '{oc_target_tokens: 20}'
# simulate a re-chunk: rebuild ONLY orphan_chunks with a different chunking config
dbt run --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select orphan_chunks --full-refresh --vars '{oc_target_tokens: 100}'
dbt test --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select relationships_orphan_embeddings_chunk_id__chunk_id__ref_orphan_chunks_
# ^ expect this to FAIL. That is the point of this test.
```

`orphan_chunks` and `orphan_embeddings` mirror this same scenario on all three cloud targets
(same baseline, re-chunk, and expected-failure sequence, run with `--target snowflake/databricks/bigquery` against the
same `relationships_orphan_embeddings_chunk_id__chunk_id__ref_orphan_chunks_` test name),
confirming the deliberate re-chunk step actually orphans rows and the relationships test actually
catches it on each engine, not just duckdb.

`attach_metadata()` and `knowledge_base()` have the identical gap on their own keys: a `chunk_id`
`attach_metadata()`'s `chunks_relation` stops producing, or a `source_key` a `knowledge_base()`
source relation stops producing, is absent from the batch and so invisible to any delta comparison
keyed on the current batch. `orphan_amd` and `orphan_kb` below extend the same relationships-test
pattern to both, rather than an active, DELETE-based sweep, because a delete driven by *absence*
cannot tell "this row was genuinely deleted upstream" from "one of the source relations came back
empty because of a transient failure." A relationships test fails visibly in the second case; a
sweep would delete every row from that source, silently, a worse outcome than the staleness it
would fix.

```bash
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select orphan_chunks orphan_amd orphan_kb_source orphan_kb_valid_keys orphan_kb \
  --full-refresh --vars '{oc_target_tokens: 20}'
# simulate a re-chunk (orphan_amd's gap) and a source deleting a row (orphan_kb's gap)
dbt run --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select orphan_chunks --full-refresh --vars '{oc_target_tokens: 100}'
dbt run --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select orphan_kb_source orphan_kb_valid_keys --full-refresh --vars '{ok_include_k3: false}'
dbt test --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select relationships_orphan_amd_chunk_id__chunk_id__ref_orphan_chunks_ \
           relationships_orphan_kb_source_key__source_key__ref_orphan_kb_valid_keys_
# ^ expect both to FAIL. That is the point of this test.
```

`orphan_kb_valid_keys` exists only because `relationships` compares raw column values against
another model's column, and `knowledge_base()`'s key (`source_type || '::' || source_id`) is
synthesized, not a column any source relation carries on its own; this view re-derives it from
`orphan_kb_source`'s current rows so there is something to point the test at.

Mirrored on all three cloud targets against the same test names, confirming both the re-chunk and
the source-deletion step actually orphan rows, and both relationships tests actually catch it, on
every engine.

Rebuild all five models together with matching vars afterward to leave the local database clean.

### 4.5 The chunk partition-delta step

`chunk()` computes a `partition_hash` over its input units and compares it against the stored value
itself, rebuilding only the partitions whose content changed. Whether an untouched partition is
genuinely *skipped*, and whether a partition that loses a chunk has that chunk *deleted*, only
appears across sequential runs:

```bash
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select chunk_edge_units chunk_edges chunk_edges_labeled chunk_delta_units chunk_delta \
           assert_chunk_edges assert_chunk_null_lineage assert_chunk_fingerprint assert_chunk_delta \
  --full-refresh
# ^ cd_phase defaults to 1: clean(2 units), grow(2), shrink(3 -> 2 chunks).
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select chunk_delta_units chunk_delta assert_chunk_delta --vars '{cd_phase: 2}'
# ^ grow gains a unit, shrink loses one (vacating a chunk), new appears, clean is untouched.
```

Phase 1 **requires** `--full-refresh`. Running it incrementally over a phase-2 table leaves the
`new` partition behind: it is absent from the source, so it produces no rows, so no incremental
strategy keyed on the partitions present in the incoming data ever deletes it. A partition deleted
from source outlives its chunks until a full refresh. Reproduced on Snowflake and Databricks
(5 rows, `new` surviving); BigQuery does not show it only because `chunk_delta` is a table there.

`assert_chunk_delta`'s load-bearing branch is `orphan_chunk_survived_shrink`. Whole-partition
replacement is required because a re-chunk can renumber or drop a partition's chunks, so `chunk_id`
is not a stable identity to merge on. A `merge` on `partition_key` gets this silently wrong: it
matches both stored `shrink` rows against the single incoming row and updates both, leaving a
duplicate while reporting success. That is why BigQuery, whose only strategies are `merge`,
`insert_overwrite` (which cannot partition on a `STRING` key) and `microbatch`, materializes
`chunk_delta` as a table instead. `chunk()` is deterministic and zero-AI-cost, so a BigQuery full
rebuild costs warehouse compute only, and a downstream `embed()` still skips re-embedding because
`chunk_text` is byte-identical for unchanged partitions.

The same two-build sequence runs on all three cloud targets with byte-identical model and test
files (`--target snowflake/databricks/bigquery`), which is what makes the four-tier parity claim
in ADR-0015 real here rather than nominal.

`assert_chunk_fingerprint` needs no warehouse data and no second run: it compares
`chunk_fn_fingerprint` across argument sets in Jinja and fails naming any argument the fingerprint
ignores. Without that fingerprint folded into `partition_hash`, changing `target_tokens` alone
leaves every input byte identical, so no partition looks dirty and the model serves output built
under the previous configuration while reporting success.

### 4.6 The attach_metadata content-hash delta step

`attach_metadata` computes its own `content_hash` from `chunk_text` plus every `metadata_columns`
value, and compares it against the stored value on `this`, the same idea as 4.5 but simpler:
`attach_metadata` never invents or renumbers `chunk_id`, so a plain `merge` on `chunk_id` is safe on
every engine, no per-adapter strategy needed. Whether a metadata-only edit (chunk text unchanged,
a joined column changed) is actually caught only appears across sequential runs:

```bash
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select attach_metadata_delta_meta_stg attach_metadata_delta assert_attach_metadata_delta \
  --full-refresh
# ^ amd_edit_id defaults to 'none': the unedited baseline.
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select attach_metadata_delta_meta_stg attach_metadata_delta assert_attach_metadata_delta \
  --vars '{amd_edit_id: doc_2}'
# ^ doc_2's title changes; chunk_docs' own chunk_text for doc_2 is untouched.
```

`content_hash` is computed inside `attach_metadata()` itself, from the same `metadata_columns` list
already passed to it, so there is exactly one place this formula is written, not a second,
caller-maintained copy that can silently drift out of sync. Two mutations were run and reverted to
confirm the test is not vacuous: removing the delta filter entirely (every row rewritten every run)
failed `untouched_chunk_was_rewritten`, and dropping `metadata_columns` from the hash formula (the
exact shape of the original bug) failed `edited_chunk_not_rebuilt`, four failures each time.

No config fingerprint is needed the way chunk's `chunk_fn_fingerprint` is. `in_text` and
`metadata_columns` are not blind spots the way `target_tokens` was for chunk: both already flow
into what gets hashed, `in_text` through `chunk_text` itself and `metadata_columns` through the
values it lists. Confirmed directly: reordering `metadata_columns`, toggling `in_text`, and adding a
third column each changed every row's hash relative to a baseline with none of the three affecting
it back.

The same two-build sequence runs on all three cloud targets with byte-identical model and test
files.

### 4.7 The knowledge_base per-arm delta step

`knowledge_base` synthesizes `source_key` (`source_type || '::' || source_id`) and computes
`content_hash` per source arm, inside its own CTEs, then filters each arm to new-or-changed rows
before the union rather than wrapping the whole union in an outer filter. Whether a whole untouched
source is genuinely skipped, not just correctly deduplicated after a full re-scan, only appears
across sequential runs:

```bash
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select kb_delta_tickets_stg kb_delta_calls_stg kb_delta assert_kb_delta --full-refresh
# ^ kbd_phase defaults to 1: tickets t1/t2, calls c1.
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select kb_delta_tickets_stg kb_delta_calls_stg kb_delta assert_kb_delta --vars '{kbd_phase: 2}'
# ^ t2's text is edited, t3 appears, t1 and the ENTIRE calls source (c1) are untouched.
```

The calls arm is the point of this fixture. An outer wrap-and-filter around the whole union would
still be correct, no duplicate rows, but it would fully scan, cast, and union the calls source
every run regardless, before an outer `WHERE` ever narrowed anything. Filtering inside each arm
means an untouched source contributes nothing past its own delta check, which is the actual compute
saving going incremental is supposed to buy here.

Two mutations were run and reverted to confirm the test is not vacuous: removing the delta filter
entirely (every row rewritten every run) failed `untouched_row_was_rewritten`, and dropping `text`
from the hash formula (the same shape as the original caller-assembled bug this pattern replaces)
failed `edited_row_not_rebuilt`, three failures each time.

`content_hash` deliberately does not cover `embedding`. Casting a `VECTOR`/`ARRAY` is itself
engine-specific (the same reason `knowledge_base`'s own `text`/`ts` casts exist and `embedding`
does not get one), and hashing one would reintroduce that non-portability for a narrow benefit.
Consequence, not oversight: a source row whose upstream embedding changes with its text held
constant is not caught as dirty here on that basis alone. `account_key` IS covered: a row
re-parented to a different account is a real content change, not something to leave frozen.

Merge on `source_key` is safe on every engine, the same reasoning as `attach_metadata`:
`knowledge_base` never invents or renumbers a key, every row maps 1:1 to exactly one upstream row.
Confirmed directly on all four engines, no BigQuery carve-out needed, unlike `chunk`.

The cloud fixture reuses `embeddings`' already-computed vectors rather than calling `embed()`
again (verified present on all three targets before every build in this session, to confirm zero
new AI spend), and remaps its real `utterance_id` values onto the same `t1`/`t2`/`t3`/`c1` synthetic
ids the duckdb fixture uses, so `assert_kb_delta.sql` is byte-identical in both projects rather than
diverging over fixture-specific identifiers.

### 4.8 attach_metadata's null-metadata-value edge case

`amd_null_meta_source` joins against `chunk_docs`' real partition keys rather than a hand-built
chunks fixture: `doc_1` gets one row of real values (a baseline for contrast), `doc_2` gets TWO
rows that both agree on null for every column, `doc_3` gets no row at all (the ordinary
unmatched-`LEFT JOIN` case). `assert_amd_null_meta` proves a consistently-null value passes
through cleanly rather than assuming it from `attach_metadata`'s DISTINCT-collapse docstring
alone: `doc_2`'s two agreeing-null rows collapse to one (no fan-out, `chunk_id` stays unique),
`content_hash` stays non-null even when every hashed input is null (already coalesced in the
formula), and the `in_text=True` variant (`amd_null_meta_text`) renders an empty line for the
null value (`"title: \n"`) rather than a literal `"None"`/`"null"` string, with the block still
prepended at all.

**The existing functional-dependency guard had a blind spot this surfaced.**
`assert_metadata_source_fd` used to check `count(distinct col) > 1` per key, but
`COUNT(DISTINCT col)` silently ignores `NULL`, so a key with one row at `col = 'x'` and another at
`col = NULL` passed this guard undetected, exactly the shape `attach_metadata`'s real join would
still correctly fan out on (a row-tuple `DISTINCT` has no such blind spot, `(key, NULL)` and
`(key, 'x')` are different rows under `DISTINCT`, the same semantics the real join relies on). The
guard now mirrors that row-tuple `DISTINCT` collapse directly instead of a per-column
`count(distinct col)`, so it can't miss a null-vs-value conflict `attach_metadata` itself would
catch.

### 4.9 chunk()'s downstream embed() no-op across a pure fingerprint bump

ADR-0029 reasoned from determinism that a `chunk_fn_fingerprint` bump (a config change, no
content change) forces a full whole-partition rebuild but leaves `chunk_text` byte-identical, so
a downstream content-hash delta should see nothing to re-embed. This fixture measures that
directly instead of only reasoning about it.

`chunk_fp_probe_units` carries `unit_id_alias`, a column holding the exact same values as
`unit_id` under a different name. `chunk_fp_probe_chunks` passes `id_column=var('fp_probe_id_col',
'unit_id')` to `chunk()`; swapping that var to `'unit_id_alias'` changes `chunk_fn_fingerprint`
(`id_column` is hashed by name) without changing anything `chunk()` actually outputs, since the
aliased column resolves to identical values.

```bash
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select chunk_fp_probe_units chunk_fp_probe_chunks chunk_fp_probe_chunks_hashed \
  chunk_fp_probe_embed assert_chunk_fp_probe --full-refresh
# ^ fp_probe_id_col defaults to 'unit_id': baseline, 2 chunks, embed row_count=2.
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select chunk_fp_probe_chunks chunk_fp_probe_chunks_hashed chunk_fp_probe_embed \
  assert_chunk_fp_probe --vars '{fp_probe_id_col: unit_id_alias}'
# ^ fingerprint-only bump: embed row_count must be 0.
```

Confirmed directly (not just via the test, by inspecting the underlying table): `partition_hash`
changed for both partitions between the two builds (`c9558cac...`→`0c660296...`,
`bd8e8253...`→`64573ed1...`), proving `chunk()` genuinely treated both as dirty and did a real
whole-partition replace. `chunk_id`/`chunk_text` stayed byte-identical across that replace, and
`embedded_at` on the downstream `chunk_fp_probe_embed` row stayed frozen at its phase-1 value,
direct proof no re-embedding happened, not an artifact of the row_count measurement alone.

`chunk_fp_probe_embed`'s `embedding` is a fixed stand-in literal, not a real `embed()` call, the
same precedent `content_hash_delta` uses on every tier: the mechanism under test is the
delta/metering plumbing (does `log_ai_run`'s `row_count` correctly read zero when `chunk()`
rebuilds a partition but `chunk_text` doesn't change), not `embed()`'s own AI behavior, so no AI
spend or cloud warehouse is needed to verify it.

### 4.10 version_guard adopting a pre-existing table with no version column

Automated in CI (`deterministic-tests`), documented here because §4 never described it. The
first `version_guard` run against a table that predates the version column used to raise
"column does not exist". The fix detects the missing column, reprocesses every row, and stamps
the version. duckdb only: this is `get_columns_in_relation` behavior, engine-agnostic, so a
cloud copy would test the same code path twice.

```bash
dbt run --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select vg_adopt --full-refresh --vars '{vg_legacy: true}'
# ^ builds vg_adopt in the LEGACY shape, with no model_version column.
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --indirect-selection cautious \
  --select vg_adopt assert_vg_adopt --vars '{vg_legacy: false, vg_ver: v1}'
# ^ first guarded run against that table: must succeed and stamp v1 on every row.
```

A non-zero exit on the second command means the adoption path regressed. `assert_vg_adopt` then
pins the stamped result.

---

### 4.11 The full validation passes, in order

§4.1 through §4.10 each describe one sequence in isolation. This section is the order to run
them in, what state each assumes, and how to get back to a clean baseline. There is no runner
script. This is a procedure a person executes.

**Two passes, not one.** §4.2 (`logged_delta`) and §4.9 (the `chunk_fp_probe_*` chain) have no
cloud counterpart, so the cloud pass is genuinely shorter. That is a tier difference, not an
omission. §4.8 appears in neither pass: it describes a fixture and its edge case, and has no
sequence to run. §4.10 is duckdb-only for the same reason as §4.2 and §4.9.

**Every selective step carries `--indirect-selection cautious`.** Without it dbt's default
*eager* selection pulls in singular tests whose models the step never built, and they fail for
reasons unrelated to what the step is testing. On duckdb, the §4.3 selection drags in five such
tests. Adding `cautious` reduces it to one. On the cloud targets the same selection fails
`assert_run_log` with `Got 2 results`. Do not drop the flag.

Set these once per pass:

```bash
# duckdb pass
DBT=integration_tests/duckdb/.venv/bin/dbt
D="--project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb"
```

```bash
# cloud pass
DBT=integration_tests/cloud/.venv/bin/dbt   # Fusion: DBT=dbtf
C="--project-dir integration_tests/cloud --target snowflake"   # repeat for databricks, bigquery
```

> **Running the cloud pass under Fusion on BigQuery requires a different working directory.**
> Fusion resolves `seed-paths` against the process CWD rather than against `--project-dir`, so
> `dbt build --project-dir integration_tests/cloud --target bigquery` fails all 5 seeds. Run it
> from inside the project instead, with no `--project-dir`:
>
> ```bash
> cd integration_tests/cloud
> dbtf build --target bigquery --full-refresh --vars '{ai_functions_enabled: true}'
> ```
>
> Snowflake and Databricks are unaffected under Fusion and run from the repo root like Core does.
> The seed failure is the whole symptom, so do not "correct" the command back to the
> `--project-dir` shape when it reappears in a diff. Core resolves `seed-paths` against
> `--project-dir` on every target and needs none of this.

Every cloud step that reaches an AI wrapper also needs `--vars '{ai_functions_enabled: true}'`
(§3.3). It is written out in full below rather than hidden behind a variable, so no step can be
copied without the opt-in visible.

Use the per-project venvs rather than a global `dbt`. A global binary on a dev machine may be
Fusion, which changes what you are testing without saying so.

#### duckdb pass (free, no credentials)

| # | Step | Assumes | Pass looks like |
|---|---|---|---|
| 1 | Full-refresh baseline: `$DBT build $D --full-refresh` | anything | `PASS=206` |
| 2 | §4.1 version guard, v1 then v2 | step 1 | both runs green |
| 3 | §4.10 `vg_adopt` adoption | step 1 | second run green, v1 stamped |
| 4 | §4.2 `logged_delta` phase 2 | step 1 | `row_count = 5` |
| 5 | §4.3 content-hash delta phase 2 | a *fresh* step 1 | `row_count = 1` |
| 6 | §4.5 chunk partition delta phase 2 | step 1 | per §4.5 |
| 7 | §4.6 attach_metadata delta phase 2 | step 1 | per §4.6 |
| 8 | §4.7 knowledge_base per-arm delta phase 2 | step 1 | per §4.7 |
| 9 | §4.9 chunk fingerprint bump | step 1 | embed `row_count = 0` |
| 10 | §4.4 orphan sequence | step 1 | the `relationships` test **FAILS** with `Got 6 results` |
| 11 | **Cleanup rebuild (mandatory)** | step 10 | see below |

Steps 2 and 3 are also run by CI (`deterministic-tests`), so by hand they are a duplicate. Run
them anyway when validating a change to `version_guard` itself.

**Each phase-2 step consumes its delta.** Running step 5 twice without re-establishing the
baseline in between fails `assert_content_hash_delta` with `row_count = 0`, which reads exactly
like a real defect and is not one. If you need to repeat a phase-2 step, re-run its own baseline
command first.

**Step 11, the cleanup, is not optional.** Step 10 deliberately strands rows and leaves the
database inconsistent:

```bash
$DBT build $D --indirect-selection cautious --full-refresh \
  --select orphan_chunks orphan_embeddings --vars '{oc_target_tokens: 20}'
$DBT build $D --full-refresh          # back to PASS=206
```

#### cloud pass (real AI calls, run once per target)

| # | Step | Assumes | Pass looks like |
|---|---|---|---|
| 1 | Full-refresh baseline: `$DBT build $C --full-refresh --vars '{ai_functions_enabled: true}'` | anything | `TOTAL=172`, ideally `PASS=172` |
| 2 | §4.1 version guard, v1 then v2 | step 1 | both runs green |
| 3 | §4.3 content-hash delta phase 2 | a *fresh* step 1 | `row_count = 1` |
| 4 | §4.5 chunk partition delta phase 2 | step 1 | per §4.5 |
| 5 | §4.6 attach_metadata delta phase 2 | step 1 | per §4.6 |
| 6 | §4.7 knowledge_base per-arm delta phase 2 | step 1 | per §4.7 |
| 7 | §4.4 orphan sequence | step 1 | the `relationships` test **FAILS** |
| 8 | **Cleanup rebuild (mandatory)** | step 7 | `TOTAL=172` again |

§4.1's cloud half used to run in a CI job. That job is gone (it never once executed and depended
on a repo secret that never existed), so this pass is now the only thing covering it.

On step 1, a `PASS=131 ERROR=3` on Snowflake with `assert_wrappers_nonnull`,
`assert_extract_conforms`, and `assert_flatten_conforms` failing together is the transient null
described in §5, not a regression. Rebuild and re-test before investigating.

Cleanup for step 8 mirrors the duckdb one, then a full rebuild:

```bash
$DBT build $C --indirect-selection cautious --full-refresh \
  --select orphan_chunks orphan_embeddings --vars '{oc_target_tokens: 20}'
$DBT build $C --full-refresh --vars '{ai_functions_enabled: true}'
```

The pass is complete when the final rebuild is clean. Do not leave a warehouse mid-sequence.

### 4.12 The AI-backed incremental embed model (multi-run, cloud only for the real call)

`embed_delta` is the production pattern the README presents, embed() plus content_hash plus
version_guard plus incremental_delta_predicate on ONE incremental model, run for real for the
first time. It pins `full_refresh=var('allow_full_reembed', false)`, which is what
`require_full_refresh_gate` requires and also what makes the model safe: dbt's own `full_refresh`
config overrides a bare `--full-refresh` CLI flag per node, so an unrelated `--full-refresh` on a
shared job cannot silently re-bill this model's whole corpus.

That means rebuilding the baseline is a deliberate opt-in, not the default `--full-refresh`
behavior every other fixture in this file gets. Forgetting the `allow_full_reembed` var does not
break anything; it just means the "baseline" step below re-embeds nothing, because the previous
build's rows are still there and the config has already fenced off the CLI flag.

```bash
# 1) Baseline: embeds all 10 rows. allow_full_reembed is required here, not optional --full-refresh.
$DBT build $D --select embed_delta_stg embed_delta assert_embed_delta --indirect-selection cautious \
  --full-refresh --vars '{allow_full_reembed: true}'

# 2) Phase 2: edits utterance_id 4's text. Embeds exactly that one row; every other embedded_at
#    stays frozen at its phase-1 value.
$DBT build $D --select embed_delta_stg embed_delta assert_embed_delta --indirect-selection cautious \
  --vars '{ed_edit_id: 4}'
```

On the cloud pass, add `ai_functions_enabled: true` to both `--vars` maps, same as every other
step here that reaches an AI wrapper. Cost: 10 embed calls in step 1, 1 in step 2, per target.

**Confirm the gate, not just the model.** After step 2, run a bare `$DBT build $D --full-refresh
--vars '{ed_edit_id: 4}'` (cloud: add `ai_functions_enabled: true`) with no `allow_full_reembed`.
The model must NOT re-embed: `assert_embed_delta` makes no row-count claim on that shape, only its
invariants (no null embeddings, corpus size unchanged, exactly two distinct `embedded_at` values
across the table), so a passing build here means the gate held, not that the assertion was too
weak to notice a break. This is the live path `require_full_refresh_gate` never had before this
model existed.

duckdb runs the same two steps on the established stand-in-literal precedent, continuously, for
free, and proves the plumbing; it cannot exercise the gate itself, which lives inside `embed()`
and never fires without a real AI call. `probe_full_refresh_gate` (§ci.yml) covers that macro's
raise path separately.

### 4.13 `create_vector_index`'s live cycle (manual, opt-in, not part of either pass)

Not part of §4.11's duckdb or cloud pass, and not run by CI. `create_vector_index` creates an
EXTERNAL, separately-billed, idle-serving object with its own lifecycle independent of dbt, so
running this is a deliberate, occasional choice, not something either pass exercises by default.
A create is not validated as done here until its matching drop has been confirmed too; do not
stop partway through this section.

**Snowflake (Cortex Search service).** The service auto-embeds a TEXT column; it does not take a
pre-computed embedding column, and the base query must select only the search column plus any
`attributes`, never every column on the relation. Confirmed live: passing an already-embedded
`VECTOR` column, or a relation carrying one under a bare `select *`, both raise on the warehouse
side rather than compiling to something silently wrong.

```bash
dbt run-operation create_vector_index --project-dir integration_tests/cloud --target snowflake \
  --args '{name: ce_manual_idx, relation: embeddings, column: utterance_text, attributes: [call_id], warehouse: <your warehouse>}'

# confirm it exists (Snowflake): SHOW CORTEX SEARCH SERVICES LIKE 'ce_manual_idx';

dbt run-operation drop_vector_index --project-dir integration_tests/cloud --target snowflake \
  --args '{name: ce_manual_idx}'
```

**BigQuery (vector index).** `CREATE VECTOR INDEX` with `index_type: IVF` requires at least 5,000
rows in the base table; confirmed live that the 10-row integration fixtures raise "Total rows 10
is smaller than min allowed 5000." Point this at a real corpus sized for it, not at this
project's fixtures. `DROP VECTOR INDEX` also requires the `ON <table>` clause, unlike Snowflake's
drop, which takes only the service name; `relation=` is a required argument on
`drop_vector_index` for BigQuery for that reason.

```bash
dbt run-operation create_vector_index --project-dir integration_tests/cloud --target bigquery \
  --args '{name: ce_manual_idx, relation: "<project>.<dataset>.<a 5000+ row table>", column: embedding, distance_type: COSINE, index_type: IVF}'

# confirm it exists (BigQuery):
#   select index_name, index_status from `<project>.<dataset>`.INFORMATION_SCHEMA.VECTOR_INDEXES;
# TEMPORARILY DISABLED with 0% coverage right after creation is expected; BigQuery builds it
# asynchronously. Do not wait for ACTIVE before proceeding to the drop below.

dbt run-operation drop_vector_index --project-dir integration_tests/cloud --target bigquery \
  --args '{name: ce_manual_idx, relation: "<project>.<dataset>.<the same table>"}'
```

**Databricks.** Both `create_vector_index` and `drop_vector_index` raise on Databricks by design,
pointing at the Vector Search API/SDK. There is nothing to run here; the raise itself is what
`assert_create_vector_index_ddl`'s sibling probes cover on duckdb, credential-free.

Dropping the underlying table before dropping the index removes the index too on BigQuery
(confirmed live); that is not a substitute for running `drop_vector_index`, since a real
consumer's base table is not disposable the way a scratch table for this validation is.

### 4.14 `print_embedding_canary_model_delta` (manual, opt-in, cloud only)

Not part of either pass. Its own docstring says why: results belong in ADR-0026's Consequences
section, not in any baseline or CI gate, and it is run manually by a maintainer, not
continuously. Confirmed live on Snowflake: the same model passed as both `model_a` and `model_b`
prints similarity `1.0` for all four probes, proving the embed/serialize/compare plumbing runs
end to end.

```bash
dbt run-operation print_embedding_canary_model_delta --project-dir integration_tests/cloud \
  --target snowflake --vars '{ai_functions_enabled: true}' \
  --args '{model_a: <model>, model_b: <a same-dimension model>}'
```

`model_a` and `model_b` must share an output dimension. Confirmed live: pairing
`snowflake-arctic-embed-m-v1.5` (768-dim) against `snowflake-arctic-embed-l-v2.0` (1024-dim)
raises "Vector value being cast to a vector is not an array or vector, or has incorrect
dimension," because `canary_cosine_similarity`'s Snowflake branch casts through one literal,
project-wide dimension. This is not a bug in the operation. It matches the drift event it exists
to measure: a provider updating a model behind a stable alias, which does not change output
dimension.

---

## 5. What to look out for in the results

Read failures by capability. "Fail rows only" tests return the offending rows; the row's first
column names the problem (e.g. `wrong_top_hit`, `bad_accuracy`, `extract_null`).

| Test | Passing result | Red flags & how to read them |
|---|---|---|
| `assert_eval_metrics` | 0 rows | `bad_accuracy` → `eval` math or `type_float` cast wrong on this engine. `bad_shape` → the full-outer-join label set changed. Metrics are exact (0.75 / 1.0 / 0.5) — any drift is a real bug, **not** float noise. |
| `assert_grounded`, `grounded` generic | 0 rows | A returned row = a quote that is **not** a substring of its source after case/whitespace normalization → `contains`/`collapse_ws`/`norm_text` mis-rendered for this dialect (e.g. BigQuery raw-string regex, Snowflake's 4th-arg gotcha). |
| `assert_conforms_catches` | 0 rows | `schema_enum` failed to resolve the taxonomy, or `IN (...)` list built wrong. |
| `assert_search` (LIVE) | 0 rows | `wrong_count` ≠ 3 → `top_k`/`VECTOR_SEARCH` wiring off (watch **BigQuery's** divergent table-function path). `not_descending` → ordering/score sign wrong (BigQuery uses `1 - distance`). `score_out_of_range` → not cosine. `wrong_top_hit` → the near-identical utterance didn't rank #1 → **embedding quality / wrong embedding model**, or query embedded with a different model than the corpus. |
| `assert_flatten_conforms` (LIVE) | 0 rows | A row = the flattened `signal` is null or off-taxonomy. Null → `field` path wrong for this engine's output shape (VARIANT `:` / STRUCT `.` / JSON `get_json_object`). Off-taxonomy value → the model ignored the schema (most likely on **BigQuery**, where the enum is prompt-constrained only, not schema-enforced). |
| `assert_generate_text` (LIVE) | 0 rows | Empty/null text → `text` didn't extract the payload — watch **BigQuery's** `(...).result` struct access. |
| `assert_wrappers_nonnull` (LIVE) | 0 rows | `<wrapper>_null` → that wrapper returned nothing on this account (bad endpoint/model var, content filter, unsupported warehouse tier). Cross-check the model var and the prerequisite (Databricks: DBR 15.4 LTS+, not on SQL Classic). **On Snowflake a null can also be transient**: see the note below this table. |
| `assert_signals_conform` (LIVE) | 0 rows | A row = `classify`'s normalized scalar label is null or off-taxonomy. Null → the per-engine unwrap is wrong (Snowflake `:labels[0]` / BigQuery `.<field>`) — see §6. Off-taxonomy → the model ignored the label set. |
| `assert_extract_conforms` (LIVE) | 0 rows | A row = the flattened extract `signal` is null or off-taxonomy. Null → the `field` path is wrong for this engine's extract shape (Snowflake's `:response` envelope is unwrapped in the wrapper; if BigQuery returns null, its STRUCT field access is wrong). |
| `assert_extract_grounded` (LIVE, behavioral) | 0 rows | A row = the model returned an evidence quote that is **not** in the source utterance (a hallucinated quote). This surfaces real extraction quality — it can legitimately fail if the model paraphrases instead of quoting verbatim; investigate the row before assuming a code bug. |
| `assert_kb` (LIVE) | 0 rows | `bad_row_count` (≠20) or `missing_source_type` → `knowledge_base`'s union/normalization didn't run as expected on this engine. `null_lineage_or_shape` → a common-shape column (source_id / account_key / embedding / text / source_type) came out null. |
| `assert_run_log` (LIVE) | 0 rows | `no_classify_row` → `log_ai_run`'s post-hook INSERT never landed (hook error / ordering). `bad_values` → `row_count`≠10, `est_tokens` null/≤0, or `run_at` null → a cross-engine cast/typing problem in the log INSERT (the classic BigQuery pitfall). |
| `assert_versioned` (multi-run) | 0 rows at each version | `wrong_version` after the v2 run → the guard did **not** reprocess on a version bump (delta filter wasn't skipped). `bad_count_or_dupes` → the `unique_key` merge duplicated instead of replacing. |
| `assert_run_log` (duckdb) | 0 rows | If it fails after a **repeat** build, it's the append-only log accumulating — rebuild with `--full-refresh` (see §2). |
| `assert_content_hash_delta` (duckdb, multi-run, §4.3) | 0 rows | `wrong_row_count` ≠ 1 on the phase-2 run → the content-hash delta condition isn't isolating the single changed row (0 → frozen everything, 10 → reprocessed the whole corpus). `edited_row_not_reembedded` → the edited row's `embedded_at` didn't actually update, the delta predicate found it but the merge didn't touch it. |
| `relationships_orphan_embeddings_chunk_id__...` (duckdb, multi-run, §4.4) | 0 rows normally; **expected to fail** after the deliberate re-chunk step | This is the one test in this file meant to fail on command. If it *doesn't* fail after §4.4's steps, the relationships test isn't actually catching the orphan. |
| circuit-breaker trip (§2) | **non-zero exit** | If it exits 0, `guard_batch` failed to raise over the ceiling. |

> **Snowflake only: a transient null from `generate` and `extract`.**
>
> About one Snowflake build in ten, `generate` and `extract` return null for a few rows. The
> models themselves still report `SUCCESS 10`, so the build looks fine. Three tests then fail
> together: `assert_wrappers_nonnull`, `assert_extract_conforms`, and `assert_flatten_conforms`.
>
> Those three failures are one event, not three. `extract_flat` is built from `extract`, and
> `flatten` is built from `generate`, so the same nulls are caught three times.
>
> **How to recognize it.** The row count on `assert_wrappers_nonnull` equals the other two added
> together. Seen four times so far: 3=2+1, 4=1+3, 4=3+1, 5=2+3. Twice the failing rows were read
> directly, and both times they held only `extract_null` and `generate_null`, never
> `classify_null` or `embed_null`. The affected row ids change every time, so no particular
> fixture text is causing it.
>
> **What to do.** Rebuild the models, then run the tests again. Running `dbt test` on its own
> tells you nothing, because it re-reads the output already stored in the table and fails the
> same way. The nulls happen when the model is built. A clean rebuild means it was this. The
> same rows failing again means it was not.
>
> **Why this is not in §6's list of tests that fail from model nondeterminism.** A null means
> the call silently failed, and catching that is the whole reason `assert_wrappers_nonnull`
> exists. Filing it as expected noise would teach people to ignore a real signal. Not seen on
> Databricks or BigQuery, where 25 consecutive rebuilds of these models were clean (2026-09-24).

General cloud red flags: an opaque SQL error at build (not a clean `*` compiler error) usually
means an **unmet prerequisite**: Databricks on a SQL Classic warehouse or below DBR 15.4 LTS
(the runtime check is a documented no-op today, so this surfaces as an opaque SQL error rather
than a named one), or a BigQuery project without the AI API enabled.

---

## 6. Known coverage gaps & deferred items

What remains uncovered or conditional (everything else is now covered on all three warehouses):

- **`create_vector_index`'s live cycle is manual, not continuous.** §4.13 documents a
  create-and-drop cycle for Snowflake and BigQuery, confirmed live, but it is opt-in and outside
  both passes because the objects it creates are external, separately billed, and idle-serving.
  What CI does cover on every change, credential-free: `default__` and `databricks__` raise, and
  the Snowflake and BigQuery DDL strings are asserted as assembled text by
  `assert_create_vector_index_ddl`. Running the live cycle found two real defects in the shipped
  macros, both now fixed: `snowflake__create_vector_index`'s base query selected every column on
  the relation, which raises the moment that relation carries a `VECTOR` column, the realistic
  case for anything with pre-computed embeddings; and `bigquery__drop_vector_index` omitted the
  `ON <table>` clause BigQuery's `DROP VECTOR INDEX` requires, which would have made every drop
  fail.
- **The Databricks runtime prerequisite is documented but unenforced.**
  `require_databricks_ai_runtime()` has an empty body. The real requirement is DBR 15.4 LTS or
  above and not Databricks SQL Classic. Enforcing it needs a `current_version()` round trip at
  compile time on every AI-calling model, which is a cost and a design decision, and it cannot be
  validated without a Databricks warehouse. Until then an unmet prerequisite is an opaque SQL
  error rather than a named one.
- **The cloud suite never runs in CI.** It runs only locally, against your own profile, by
  following §4.11's cloud pass. A `live-battery` job existed until it was deleted: it was gated
  on `workflow_dispatch`, was never once dispatched across 54 recorded runs, and depended on a
  repo secret that was never created, so it had never executed. On a normal change the cloud AI
  paths are **parsed, not executed**, and continuous coverage is the duckdb layer.
- **Some live tests are behavioral, not deterministic gates.** `assert_search` (top-hit ranking),
  the `*_conforms_*` checks, and `assert_extract_grounded` depend on live model output, so they can
  fail from model nondeterminism rather than a code bug. Read a failing row before assuming a regression.
- **BigQuery classify/extract STRUCT field access is assumed-from-docs** (Snowflake + Databricks
  shapes are confirmed as of 2026-07-29). `assert_signals_conform` / `assert_extract_conforms` (on `--target bigquery`)
  are the confirmation — a **null** result means the `.<field>` path is wrong for BigQuery.
- **Drift detection is bounded by how often someone runs the cloud pass.** `embedding_canary`
  finds provider drift by comparing runs spaced apart in time, and nothing runs it on a
  schedule: no CI job reaches a warehouse, the repository holds no Actions secrets, and adding
  them plus a scheduled workflow was decided against. A vendor changing a pinned model's output
  is therefore invisible until the next manual cloud pass. This is a constraint on how the
  capability is operated here, not a gap in the suite or in ADR-0026's design.
- **BigQuery Vertex key casing** (`generationConfig`/`thinkingConfig`) — re-confirm on the first live
  BigQuery run.
- **`cost_reconciliation`** — **removed** (2026-07-29); can be re-added later over `ai_run_log`.
- **The embedding metadata surface has full functional parity across all four tiers.** The
  primitives (`content_hash`, `embedding_dimension`, `row_value_not_in`) and the full multi-run
  scenarios (§4.3's content-hash delta, §4.4's chunk_id orphaning) are confirmed on Snowflake,
  Databricks, and BigQuery, not just duckdb. `row_value_not_in()` is dispatched because BigQuery
  rejects the plain row-value `NOT IN` form and needs its subquery wrapped as a single tuple, a
  form Snowflake/Databricks both reject in turn; see ADR-0023's Reasoning.
- **Some hardening fixes are covered on duckdb only, by design** — they exercise engine-agnostic dbt
  or Jinja, so duckdb is representative and a cloud copy would test the same code path twice:
  the incremental **delta-scoping** of `guard_batch` via `incremental_delta_predicate`
  (pre-hook `this` + `run_query`), **`version_guard` adoption** of a column-less table
  (`get_columns_in_relation`), `vector_search`'s **tiebreaker** (standard `ORDER BY … , id`), and
  `render_prompt`'s **`{{ input }}` spacing tolerance / `prompt=none` error** (pure Jinja). See the
  `guard_delta`, `logged_filtered`, `vg_adopt`, `search_ties_*`, `assert_render_prompt_spacing`
  cases in `integration_tests/duckdb`.

**Closed (were gaps in a prior pass):**

- Classify normalized and asserted.
- Extract flattened, with conformance and evidence-groundedness asserted.
- `knowledge_base` union exercised on cloud (`assert_kb`).
- `log_ai_run` INSERT asserted on cloud (`assert_run_log`).
- `version_guard` delta and bump run on all three warehouses (§4.1).
- Content-hash delta and chunk_id orphaning run on all three warehouses (§4.3, §4.4).
- **The safety gates' raise paths.** `require_ai_functions_enabled`,
  `require_safe_materialization` and `require_full_refresh_gate` are wired into all five AI
  wrappers and none of them had a test on the raising side. Each now has a CI step that matches
  the gate's error message, plus a positive control proving the other three fail because of the
  gate rather than because duckdb cannot embed.
- **`require_ai_functions_enabled` failed open on a string.** The gate tested truthiness, and
  every non-empty string is truthy in Jinja, so `ai_functions_enabled: "false"` opened it. Jinja
  in `dbt_project.yml` renders into the YAML text before parsing and has to be quoted, which
  means the natural per-target form, `"{{ 'true' if target.name == 'prod' else 'false' }}"`,
  permitted spend on every non-prod target. The gate now normalizes to text and compares, and an
  unrecognized value raises instead of reading as off.
- **`guard_agg_batch`'s trip path**, which needed a warehouse to execute at all: its only caller
  was a pre-hook on the cloud `ai_agg` model. `guard_agg_pass` covers the pass path on duckdb
  every build and a CI step covers the raise.
- **Shipped-but-uncalled code.** `no_oversized_chunks` and `grounded` are attached in the
  integration projects; `dev_sample_filter` has a caller and a row-count assertion;
  `print_embedding_canary` runs, and `assert_canary_vector_roundtrip` proves each engine's
  `canary_vector_to_json` serializes a real vector back into something the comparison parses;
  `embedding_logic_hash()` is emitted as the audit column ADR-0025 describes and asserted to
  land. `require_bq_model` was deleted rather than tested: nothing called it, and the README
  already states `bq_connection` is optional and the `AI.*` functions need no `CREATE MODEL`.
- **The `embedding_logic_hash` call-graph walk missed bare `adapter.dispatch`.** ADR-0025 built
  the walk on the claim that every macro call is package-qualified. `chunk.sql` reaches
  `array_agg` and `string_agg` bare, so those edges were invisible. The walk now follows both,
  lives in `ci/macro_call_graph.py`, and has its own tests in `ci/test_macro_call_graph.py`.
- **The floor jobs were not testing a floor.** They pinned `dbt-core==1.11.0` but left the
  adapter unpinned, and adapters depend on `dbt-adapters` rather than a pinned core, so pip
  resolved a 1.12.x adapter on top of 1.11.0 core, a combination nobody ships. The adapters are
  pinned to 1.11.0 too.
- **`dbt_utils` was declared and never used.** No macro in the package called it, so the
  declaration was imposing a transitive install and a `<2.0.0` constraint on every consumer for
  nothing. Removed from `packages.yml`.

**Adversarial cloud coverage, added 2026-08-10,** on all three warehouses (`LIVE-VALIDATION
DEFERRED` until the next cloud pass):

- `split_sentences` **cross-engine boundary parity** against a golden set
  (`assert_split_adversarial`, catching the Snowflake divergence #7).
- Prompt-literal **backslash** and enum-label **apostrophe** escaping, executed live via a classify
  over an adversarial prompt/schema (`signals_adversarial`, #5/#6).
- `knowledge_base` **heterogeneous timestamp** (DATE vs TIMESTAMP) union (`kb_hetero`, #8).

**`log_ai_run` post-hook timing hazard, found and closed 2026-08-10 (§4.2):** `logged_filtered`
deliberately used a static filter, by its own comment, to avoid needing cross-run sequencing, so no
test ever exercised `log_ai_run` with a live `incremental_delta_predicate` filter across a genuine
incremental delta. `logged_delta` + `assert_logged_delta` now cover that case, confirmed by
temporarily reintroducing the post-hook pattern locally and watching it regress to `row_count = 0`.
The README's canonical example and `log_ai_run`'s own docstring are corrected to the pre-hook
pattern accordingly.

---

## 7. Quick reference

```bash
# Deterministic (do this constantly)
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb --full-refresh

# Guard trips (expected to FAIL)
dbt build --project-dir integration_tests/duckdb --profiles-dir integration_tests/duckdb \
  --select guard_pass --vars '{max_batch_rows: 3}'

# Structure gate for a cloud dialect (no creds; renders per-dialect SQL)
dbt parse --project-dir integration_tests/cloud --profiles-dir ci --target bigquery

# Live battery on a real warehouse (needs ~/.dbt profile; costs money).
# The --vars flag is the spend gate opt-in and is required; see §3.3.
dbt build --project-dir integration_tests/cloud --target bigquery --full-refresh \
  --vars '{ai_functions_enabled: true}'
```
