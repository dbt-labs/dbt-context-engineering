# Complete var reference

Every configuration `var` the package reads, its default, and what it controls. Set these in
`dbt_project.yml` under `vars:` (project-wide) or override per call / per target.

## Models (always explicit — the biggest cost lever)

| var | default | controls |
|---|---|---|
| `embedding_model` | `null` | model for `embed()`. **Pinned**, a corpus and its queries must share it. |
| `model_generate` | `null` | model for `generate()`. |
| `model_classify` | `null` | model for `classify()`. |
| `model_extract` | `null` | model for `extract()` (falls back to `model_generate`). |

## Spend safety

| var | default | controls |
|---|---|---|
| `ai_functions_enabled` | `false` | master gate. AI functions raise a compiler error unless this is `true` for the target. |
| `max_batch_rows` | `10000` | `guard_batch` ceiling on input rows; raises before the model runs if exceeded. |
| `max_est_tokens` | `5000000` | `guard_batch` ceiling on estimated tokens: input text, plus the prompt template and output allowance when the guard is given a `prompt`. |
| `est_output_tokens_per_row` | `null` | per-row output allowance in the estimate when a `prompt` is passed. `null` falls back to `max_output_tokens`, then 0. |
| `max_agg_group_tokens` | `100000` | `guard_agg_batch` per-group ceiling for `ai_agg` (required on Databricks). |
| `decide_choice_cap_databricks` / `decide_choice_cap_snowflake` | `255` / `32` | most labels a `decide` choice question may carry, the engines' documented limits. Raise only if the engine raised its own. |
| `decide_snowflake_preview` | `false` | `true` opts a Snowflake account with Snowflake Decision preview access into `decide` (unvalidated path). |
| `allow_full_reembed` | (unset) | wire to an incremental AI model's `full_refresh` config so a stray `--full-refresh` can't re-bill the corpus. |
| `ai_sample_rows` | `null` | `dev_sample_filter` row cap. A dev convenience, **not** a spend guard. |

## Output-side cost control

`guard_batch` can only estimate output before the run; these cap the response side.

| var | default | controls |
|---|---|---|
| `max_output_tokens` | `null` | cross-engine response cap (Snowflake `AI_COMPLETE max_tokens`, Databricks `ai_query max_tokens`, BigQuery `maxOutputTokens`). Applies to `generate` on all three. |
| `bq_thinking_budget` | `null` | **BigQuery/Gemini only.** `0` disables Gemini's default thinking (billed as output tokens); `null` = model default. |

## Logging

| var | default | controls |
|---|---|---|
| `cost_per_1k_tokens` | `null` | price used to populate `est_cost` in the run log; `null` leaves `est_cost` null. |
| `ai_run_log_relation` | `null` | where the append-only `ai_run_log` is written. |

## Chunking (deterministic, no AI)

| var | default | controls |
|---|---|---|
| `chunk_target_tokens` | `512` | target chunk size (token heuristic = `ceil(char_length/4)`). |
| `chunk_overlap_tokens` | `0` | overlap between adjacent chunks; `0` = clean, non-overlapping partition. |

## BigQuery connection

| var | default | controls |
|---|---|---|
| `bq_connection` | `null` | Vertex connection id for non-interactive jobs (optional for interactive/EUC). |
| `bq_model` | `null` | legacy `ML.*` MODEL object — not used by the `AI.*` wrappers. |

## Embedding canary (opt-in runtime drift monitor, ADR-0026)

Off by default. To enable, set `monitoring: +enabled: true` (models) and
`seeds: dbt_context_engineering: +enabled: true`, then wire the canary into a **scheduled prod
job** (it makes real, billed `embed()` calls every build).

| var | default | controls |
|---|---|---|
| `embedding_canary_similarity_threshold` | `0.999` | minimum cosine similarity a live probe must keep vs its blessed baseline. |
| `embedding_canary_vector_dimension` | `768` | **Snowflake only, required** — VECTOR needs a literal dimension; match your embedding model's output dim. |
| `embedding_canary_test_severity` | `warn` | `warn` in prod (benign wobble shouldn't fail a build); CI overrides to `error`. |
