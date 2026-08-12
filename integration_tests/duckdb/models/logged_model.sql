{{ config(
    materialized='table',
    post_hook=[
        "{{ dbt_context_engineering.log_ai_run('classify', model_name='test-model', relation=ref('fixture_utterances'), input_column='utterance_text') }}",
        "{{ dbt_context_engineering.complete_ai_run('classify', model_name='test-model') }}"
    ]
) }}

{#- Stand-in for an AI model. Its post-hooks append one row to ai_run_log sized from the seed
    (completed=false), then flip that same row to completed=true. Validates the run-log +
    hook-pair end to end on duckdb (the AI call itself is cloud-deferred). -#}
select count(*) as processed from {{ ref('fixture_utterances') }}
