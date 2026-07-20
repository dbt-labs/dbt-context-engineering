{{ config(
    materialized='table',
    pre_hook="{{ dbt_context_engineering.ce_guard_batch(ref('ce_fixture_utterances'), 'utterance_text') }}",
    post_hook="{{ dbt_context_engineering.ce_log_ai_run('classify', model_name='n/a', relation=ref('ce_fixture_utterances'), input_column='utterance_text') }}"
) }}
{#- No-AI model to validate ce_guard_batch + ce_log_ai_run + ce_ai_run_log on BigQuery. -#}
select count(*) as processed from {{ ref('ce_fixture_utterances') }}
