# Testing guide — `dbt_context_engineering`

How to run the test suite in each environment, what each run builds, and what to look for in the
results. Testing posture: structure-only for cloud AI, full deterministic execution on duckdb.

---

## 1. The three gates at a glance

| Gate | Where | Needs creds? | What it proves | How it runs |
|---|---|---|---|---|
| **Structure** | `integration_tests/cloud` (all 3 targets) | no | every macro/model/test **renders** the right per-dialect SQL (`dbt parse`, no warehouse connection) | CI `structure` job, on every PR |
| **Deterministic** | `integration_tests/duckdb` | no | everything that doesn't need a cloud AI service is **executed and asserted** on a local duckdb | CI `deterministic-tests` job, on every PR; run it locally too |
| **Live battery** | `integration_tests/cloud` (`--target snowflake/databricks/bigquery`) | **yes** | the wrappers + evaluation + accessors actually **run on the real warehouse** and return sane results | CI `live-battery` job — **opt-in**, manual `workflow_dispatch` only |

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

### 3.1 One-time setup — one profile, three targets

Add a single `dbt-context-engineering` profile to `~/.dbt/profiles.yml` (matching
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
dbt build --project-dir integration_tests/cloud --target bigquery --full-refresh
```

Or trigger all three in CI: `gh workflow run ci.yml` (the `live-battery` job; needs the repo secret
`DBT_PROFILES_YML` holding the merged profile).

Expected result: all models build and all **13** `assert_*` tests pass. A failure here is meaningful
— it means a wrapper's dialect is wrong for that account, a model returned nothing, or the AI
produced an off-taxonomy / ungrounded result. See §5.

### 3.4 First live run — recommended order

The first time you point this at a warehouse, isolate problems by building in layers instead of one
big `dbt build`:

```bash
P="--project-dir integration_tests/cloud --target bigquery"   # or --target snowflake / databricks

# 1) Deterministic first — no AI, proves connectivity + the eval/guard SQL on the real engine.
dbt build $P --full-refresh --select eval_metrics assert_eval_metrics \
  assert_grounded assert_conforms_catches

# 2) One cheap AI call — proves the model var / endpoint / prerequisite are right before spending more.
dbt build $P --select generate assert_wrappers_nonnull

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
| Run log | `logged_model`, `ai_run_log` | `assert_run_log` |
| Run log (incremental delta, multi-run) | `logged_delta` | `assert_logged_delta` via the multi-run CI step (§4.2) |
| Version guard | `versioned` | `assert_versioned` |
| Retrieval | `search_corpus`, `search_results` | `assert_vector_search` |
| Knowledge base | `kb`, `kb_search`, `source_tickets`, `source_calls` | `assert_knowledge_base`, `assert_kb_search` |
| **Evaluation (P7)** | `eval_predictions`, `eval_metrics` | `assert_eval_metrics`, `assert_grounded`, `assert_conforms`, `assert_conforms_catches`, `grounded` generic test |
| **Output accessors** | `flatten_test` | `assert_flatten`, `assert_flatten_conforms` |

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
| `assert_wrappers_nonnull` (LIVE) | 0 rows | `<wrapper>_null` → that wrapper returned nothing on this account (bad endpoint/model var, content filter, unsupported warehouse tier). Cross-check the model var and the prerequisite (Databricks serverless / DBR 18.2+). |
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
- **Some live tests are behavioral, not deterministic gates.** `assert_search` (top-hit ranking),
  the `*_conforms_*` checks, and `assert_extract_grounded` depend on live model output, so they can
  fail from model nondeterminism rather than a code bug. Read a failing row before assuming a regression.
- **BigQuery classify/extract STRUCT field access is assumed-from-docs** (Snowflake + Databricks
  shapes are confirmed as of 2026-07-29). `assert_signals_conform` / `assert_extract_conforms` (on `--target bigquery`)
  are the confirmation — a **null** result means the `.<field>` path is wrong for BigQuery.
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

**Adversarial cloud coverage, added 2026-08-10,** on all three warehouses (`LIVE-VALIDATION
DEFERRED` until the next live-battery run):

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

# Live battery on a real warehouse (needs ~/.dbt profile; costs money)
dbt build --project-dir integration_tests/cloud --target bigquery --full-refresh
```
