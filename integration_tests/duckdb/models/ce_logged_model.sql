{{ config(
    materialized='table',
    post_hook="{{ dbt_context_engineering.ce_log_ai_run('classify', model_name='test-model', relation=ref('ce_fixture_utterances'), input_column='utterance_text') }}"
) }}

{#- Stand-in for an AI model. Its post-hook appends one row to ce_ai_run_log sized from the seed.
    Validates the run-log + post-hook end to end on duckdb (the AI call itself is cloud-deferred). -#}
select count(*) as processed from {{ ref('ce_fixture_utterances') }}
