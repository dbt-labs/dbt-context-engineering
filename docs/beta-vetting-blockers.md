# What blocks each beta capability from being fully vetted

This assessment covers the six capabilities the README marks **Beta**. It is derived from the README maturity definitions, `TESTING.md` section 6, ADR-0010, ADR-0026, ADR-0028, ADR-0036, the `LIVE-VALIDATION DEFERRED` markers in `macros/` and `models/`, and the test inventory under `integration_tests/` and `.github/workflows/ci.yml`. It reflects the repository at commit `cbf22ec`.

The README defines beta as shipped but not yet fully vetted because of a larger surface area, more per-engine divergence, or narrower validation. The README defines **Validated** as built, deterministically tested where applicable, and executed on Snowflake, Databricks, BigQuery, and Redshift, with duckdb for the deterministic pieces. Each section below measures a capability against that bar.

## Summary

| Capability | Main blocker | Kind of blocker |
|---|---|---|
| `generate` / `extract` | Live tests depend on model output; Redshift and BigQuery structured output is not engine-guaranteed or not confirmed | Validation depth, engine divergence |
| `text` / `field` | Per-engine result shapes differ and the BigQuery STRUCT path is unconfirmed | Engine divergence |
| `ai_agg` / `guard_agg_batch` | Behavior genuinely differs per engine, with two no-op arguments | Engine divergence, design |
| `create_vector_index` | The create-and-drop cycle never runs, and Databricks and Redshift are unsupported | Validation depth, coverage |
| `embedding_canary` | No scheduled run exists, and Redshift is unsupported | Operational, coverage |

Two blockers apply to all six and are listed once here.

- **The cloud suite never runs in CI.** The `live-battery` job was deleted after it never executed across 54 recorded runs, because the repo secret it needed was never created. On a normal change the cloud AI paths are parsed, not executed. Continuous coverage exists only for the duckdb layer, and duckdb has no AI functions.
- **Validation used sample data only.** The README states that real production data at scale has not been validated, and that cost reconciliation against engine usage tables has not been done.

## `generate` and `extract`

Both have live tests on all four engines (`assert_wrappers_nonnull`, `assert_extract_conforms`, `assert_extract_grounded`). The gap is in how much those tests prove.

- **Tests that depend on model output.** `assert_extract_grounded` and the `*_conforms_*` checks can fail from model nondeterminism rather than a code defect. They are behavioral signals, not deterministic gates, so a green run is weaker evidence than it looks.
- **Redshift structured output is best-effort.** Bedrock returns plain text, so the schema is enforced by a prompt instruction (`redshift_output_instruction`) and caught afterward by assertions. ADR-0036 accepts this as a documented limit. It cannot reach engine-guaranteed parity with Snowflake, Databricks, and BigQuery unless Bedrock adds structured output.
- **BigQuery STRUCT field access.** `TESTING.md` records the `.<field>` path as assumed from docs and says a null from `assert_signals_conform` or `assert_extract_conforms` on `--target bigquery` is the confirmation. The README says the surface ran live on BigQuery, so confirm whether this note is stale.
- **BigQuery Vertex key casing.** `bq_model_params` uses `generationConfig` and `thinkingConfig`, and the macro comment still says to re-confirm the casing on a live run.
- **Stale vendor-surface caveats.** `generate.sql` says the vendor surface is compile-checked but not executed and that argument shapes must be re-confirmed. That conflicts with the README's claim of live execution. Either the comment is stale or the README overstates.
- **Adversarial coverage is deferred.** `extract_flat`, `kb_hetero`, and `signals_adversarial` are marked deferred until the next cloud pass.
- **Unenforced Databricks prerequisite.** `require_databricks_ai_runtime()` has an empty body, so an unmet DBR 15.4 LTS requirement surfaces as an opaque SQL error instead of a named one. Enforcing it costs a `current_version()` round trip per AI-calling model, so it is a design decision.

**To graduate:** one recorded cloud pass on each engine that closes the BigQuery and Vertex items, a decision on the Redshift best-effort caveat, and either a runtime check for Databricks or a documented decision not to add one.

## `text` and `field`

These exist to hide per-engine result shapes, which is also why they are hard to vet. Snowflake returns VARIANT, Databricks returns a JSON string, and BigQuery returns a STRUCT.

- **The cloud branches carry a deferred marker.** `field.sql` and `text.sql` both say live validation is deferred on cloud engines, and only the default JSON-string path is validated on duckdb. `assert_flatten_conforms` and `assert_generate_text` do run live, so the marker may be stale. It should be reconciled with the test inventory.
- **BigQuery is the least certain branch.** It shares the unconfirmed STRUCT access path described above.
- **Redshift reads a text result.** Because Redshift output is prompt-shaped JSON, `field` depends on the model honoring the format, so a malformed answer yields a null rather than an error.
- **`as_type` casts are lightly exercised.** The tests mostly read string fields. Integer, float, and boolean casts across the four engines have little direct coverage, and Redshift has a recorded `SUPER` to `float8` cast item.

**To graduate:** a typed-cast test matrix per engine, the BigQuery confirmation, and removal or confirmation of the stale deferred markers.

## `ai_agg` and `guard_agg_batch`

ADR-0028 says cross-adapter behavior diverges the most here. The divergence is intentional, so the blocker is partly a design question and not only missing validation.

- **Two arguments are no-ops on some engines.** `model` does nothing on Snowflake. `order_column` does nothing on BigQuery, and on Snowflake it only helps if the caller pre-sorts the `FROM` clause. A caller moving between engines gets different behavior from the same call.
- **Oversized groups behave differently.** Snowflake and BigQuery absorb them with internal map-reduce. Databricks fails the build at the `max_agg_group_tokens` ceiling. Redshift fails at the 64KB `LISTAGG` limit, which is tighter than Databricks. The ceiling is also tied to the model it was tuned for.
- **Map-reduce on Databricks and Redshift is deferred, not rejected.** ADR-0028 says to build it only if the ceiling bites often in practice, and no evidence about frequency exists yet.
- **The live tests are thin.** `assert_ai_agg` checks that each group summary is non-empty. It does not check summary quality, ordering behavior, or the ceiling under a real oversized group.
- **The guard's trip path is covered on duckdb only.** A duckdb CI step covers the raise, and `guard_agg_pass` covers the pass path. Neither runs against real token estimates from a warehouse.
- **The live validation date is recorded as 2026-08-23.** It predates the Redshift implementation, so the Redshift branch has less history.

**To graduate:** a decision on whether divergent behavior is acceptable as documented or needs the map-reduce work, plus a live test with an oversized group on each engine that checks the ceiling and the 64KB limit.

## `create_vector_index`

- **The create-and-drop cycle never runs.** It creates external, separately billed objects, so a live cycle on Snowflake and BigQuery stays out of the suite. `assert_create_vector_index_ddl` only proves the DDL text is assembled with every argument. It does not prove either warehouse accepts that DDL.
- **Databricks raises.** Vector Search is a separate API and SDK, not SQL DDL, so the macro fails with guidance and no index can be built from dbt on that engine.
- **Redshift is unsupported.** The scale path is an external service such as S3 Vectors or OpenSearch, which ADR-0036 puts out of scope.
- **Two of four engines have a working path.** That is a structural limit on how far this capability can graduate, so a cross-engine claim is not available even after live validation.
- **Lifecycle risk.** The index has idle-serving cost and its lifecycle is outside dbt. Any live test needs an explicit teardown and a cost budget.
- **Retrieval at scale is untested.** `vector_search` is validated only on the brute-force path. There is no evidence that the managed index returns comparable results or at what corpus size it pays off.

**To graduate:** a one-time recorded create, query, and drop on Snowflake and BigQuery, a stated policy for Databricks and Redshift, and a small recall comparison against brute force.

## `embedding_canary`

- **No scheduled run exists.** Drift shows up only when two runs are spaced apart in time. No CI job reaches a warehouse, the repo holds no Actions secrets, and adding a scheduled workflow was decided against. A vendor change to a pinned model is invisible until someone runs the cloud pass by hand. This is an operating constraint and not a flaw in ADR-0026's design.
- **The detection claim has never been exercised.** Plumbing tests prove the hash, baseline, and re-bless serializer work. The duckdb canary uses a stand-in vector, so a green result proves nothing about provider drift. No recorded case shows the canary catching a real model change.
- **Redshift raises.** A scalar cosine would need a correlated subquery that unnests an outer `SUPER` column, which ADR-0036 declines to ship unvalidated.
- **Setup is easy to get wrong.** The monitor is disabled by default, its baseline seed is also disabled, and Snowflake needs `embedding_canary_vector_dimension` with no default. A partial enablement fails in a confusing way.
- **The threshold is unproven.** The default similarity threshold of `0.999` has no recorded false-positive or false-negative data across engines.
- **Cost accrues on every build.** It makes real `embed()` calls, so it belongs only in a scheduled production job.

**To graduate:** a scheduled run somewhere that can hold warehouse credentials, a recorded baseline across a deliberate model change to show the alert fires, and threshold data from repeated runs.

## Suggested order of work

1. Run one full cloud pass on all four engines and record the results. This closes the BigQuery items and settles the stale deferred markers for `generate`, `extract`, `text`, and `field`.
2. Reconcile the documentation conflicts found above. The README, `TESTING.md`, the macro comments, and the skill reference at `skills/dbt-ce-ai-functions/references/functions-reference.md` disagree on what is validated.
3. Decide the intended end state for `ai_agg`, `create_vector_index`, and `embedding_canary`. Each has engines where it will not be supported, so the question is whether beta lifts per engine or the label stays until the matrix is complete.
4. Decide whether a credentialed scheduled workflow is acceptable. Without one, the canary and the live battery stay manual.

## Reconciliation results (hub #178, 2026-11-10)

Documentation conflicts were checked against the recorded cloud pass of 2026-09-25 (144 of 144 on Snowflake, Databricks and BigQuery under dbt Core and Fusion, TESTING.md section 3.3) and the Redshift pass.

- The `LIVE-VALIDATION DEFERRED` markers in `generate.sql`, `extract.sql`, `text.sql`, `field.sql` and `bq_model_params.sql` were stale. They now state what executed live and where.
- The TESTING.md notes calling BigQuery STRUCT access assumed-from-docs and the Vertex key casing unconfirmed were stale. Both are confirmed by that pass.
- The skill reference no longer says generate/extract have deferred aspects. It names the remaining limits: sample data only, and best-effort structured output on Redshift.
- The duckdb deterministic suite passes (206 of 206, dbt Core 1.12.0).
- Nothing was moved to Validated. No new billed cloud pass has run, and the remaining blockers above (typed casts, oversized `ai_agg` groups, the `create_vector_index` cycle, canary drift evidence, the Databricks prerequisite check) still stand.

## Live baseline pass (hub #178, 2026-11-10)

Step 1 of the TESTING.md section 4.11 cloud pass (`build --full-refresh` with `ai_functions_enabled: true`, dbt Core 1.12.6, project-local venvs), run once per engine. Sample data only.

| Engine | Result |
|---|---|
| Snowflake | PASS=148 ERROR=0 TOTAL=148 |
| Databricks | PASS=148 ERROR=0 TOTAL=148 |
| BigQuery | PASS=148 ERROR=0 TOTAL=148 |
| Redshift | First attempt timed out on connection before any model built (nothing billed). Retried with VPN on: PASS=140 ERROR=0 TOTAL=140 (the Redshift project has no canary or vector index models). |

TOTAL is 148, while TESTING.md section 3.3 still says 145, so that number needs updating. The multi-run delta steps (4.1 and 4.3 to 4.7) and the orphan sequence were not run in this pass.

## Databricks runtime check: live probe (hub #178, 2026-11-10)

Probed the configured Databricks warehouse, which runs the AI functions successfully (148 of 148 above).

- `select to_json(current_version())` returns `{"dbsql_version":"2026.45", ...}` with **no `dbr_version` key**. `current_version().dbr_version` is null.
- So a check written as "dbr_version >= 15.4" would fail a warehouse that works. The 15.4 LTS requirement applies to all-purpose clusters. SQL warehouses report a `dbsql_version` instead, and the docs give no minimum for it.
- Nothing in `current_version()` or `version()` says whether a warehouse is SQL Classic, the other documented exclusion.
- The probe took about 5 seconds warm and 14 seconds with a cold start, per call, which is the per-model cost of enforcing it.
- The same probe on a `databricks-classic` target reports the same shape, so no version field separates Classic from Pro.
- `ai_query` on the Classic warehouse fails with `[AI_FUNCTION_UNSUPPORTED_ERROR] The function ai_query is not supported in the current environment. It is only available in Databricks SQL Pro and Serverless. SQLSTATE: 56038`. This is a named error, so the earlier "opaque SQL error" premise was wrong for Classic.
- Databricks lists an upcoming move to DBR 17.3 LTS, which would date a hard-coded floor.
- Not reproduced: the error from an all-purpose cluster below DBR 15.4.
- Decision: do not enforce. The macro comment, TESTING.md section 6 and the README row now say so.

## Databricks all-purpose cluster probes (hub #178, 2026-11-10)

Same baseline build (`--full-refresh`, `ai_functions_enabled: true`, dbt Core 1.12.0) against two all-purpose clusters. `current_version()` on a cluster does populate `dbr_version` (14.3 reported `14.3.x-photon-scala2.12`).

| Cluster | Result |
|---|---|
| DBR 14.3 | PASS=127 ERROR=8 SKIP=13 TOTAL=148 |
| DBR 17.3 | PASS=144 ERROR=3 SKIP=1 TOTAL=148 |

DBR 14.3 failures:
- `generate`, `extract`, `generate_text`: `[UNRECOGNIZED_PARAMETER_NAME]` on `ai_query`, which has no `modelParameters` argument at this runtime. A bare `ai_query` call succeeds, so the floor matters for the wrappers, not for the function existing.
- `signals`, `signals_adversarial` (`classify`): `[AI_FUNCTION_UNSUPPORTED_ERROR]` for `ai_classify`.
- `search` and both canary tests: `[UNRESOLVED_ROUTINE]` for `vector_cosine_similarity`.

DBR 17.3 failures, all one cause:
- `search` and both canary tests: `[UNRESOLVED_ROUTINE] Cannot resolve routine vector_cosine_similarity`. Every AI wrapper (`generate`, `extract`, `classify`, `embed`, `ai_agg`, `text`, `field`) passed on 17.3.

Consequences:
- `vector_search` (README: validated on Databricks) and `embedding_canary` ran on SQL warehouses only. On both clusters tested, including 17.3, they fail because `vector_cosine_similarity` does not resolve. Validation claims for those two need a SQL-warehouse scope.
- Below the floor the failures are named Databricks errors, but they do not name the runtime version.
- Whether `vector_cosine_similarity` exists on a newer cluster runtime, or only on SQL warehouses, is not established.

### DBR 18.2 cluster

`vector_cosine_similarity` is documented as Databricks Runtime 18.1 and above. On a DBR 18.2 all-purpose cluster (`dbr_version` `18.2.x-photon-scala2.13`), `search`, `assert_search`, `assert_canary_vector_roundtrip` and `assert_embedding_canary_matches_baseline` all pass (PASS=5 ERROR=0). The run reused the `embeddings` table built by the 17.3 baseline in the same schema, so only `search` and the canary tests executed, not a full baseline.

Working support statement for Databricks, as run: AI wrappers on a SQL warehouse (tier not recorded separately) and on DBR 17.3 and above clusters; `vector_search` and `embedding_canary` on SQL warehouses and on DBR 18.1 and above clusters (tested at 18.2). Not tested: 15.4 to 16.x, and a full baseline on 18.2.

## Typed casts and oversized groups (hub #178, 2026-11-10)

New probes in both integration projects. Baselines after the change: Snowflake 152, Databricks 152 and BigQuery 152 of 152, Redshift 145 of 145, duckdb 206 of 206.

- **Typed `field` casts** (integer, number, boolean) pass on all four engines. It found a real defect: `redshift__field` could not produce a boolean, because Redshift rejects a text or varchar to boolean cast. It now maps `'true'` and `'false'` explicitly. On BigQuery a vague prompt got a null `flag` because Gemini omitted the key, which is model behavior, not a `field` defect.
- **Oversized `ai_agg` group** (1000 rows, 85,800 characters, about 21,800 estimated tokens): Snowflake, BigQuery and Databricks build it. Redshift fails with `Result size exceeds LISTAGG limit`. This size is below any model context window, so the map-reduce path and Databricks' real ceiling were not exercised.
- **`guard_agg_batch`** raises its named error on all four engines at a lowered ceiling, before any AI call. Its trip path had only been covered on duckdb.

## Caveats on this assessment

- It reads documentation and test files. It did not execute any suite, so it cannot confirm which deferred markers are stale.
- The `README` and `TESTING.md` disagree in places, and the doc above points to those places instead of choosing a side.
