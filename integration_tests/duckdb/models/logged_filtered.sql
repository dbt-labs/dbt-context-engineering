{{ config(
    materialized='table',
    post_hook="{{ dbt_context_engineering.log_ai_run('extract', model_name='filter-test', relation=ref('fixture_utterances'), input_column='utterance_text', filter='utterance_id > 5') }}"
) }}

{#- Deterministic, single-build proof that log_ai_run's `filter` scopes the METER to the rows a run
    actually processes (not the whole relation) — the meter-side twin of the guard_batch fix. The
    post-hook logs a run sized by `utterance_id > 5` (5 of the 10 seed rows). assert_log_filtered
    checks the logged row_count == the filtered count, so a regression back to whole-relation metering
    (which logged 10) fails the build. Uses an explicit predicate rather than the incremental helper so
    the assertion is exact and needs no cross-run sequencing. -#}
select count(*) as processed from {{ ref('fixture_utterances') }} where utterance_id > 5
