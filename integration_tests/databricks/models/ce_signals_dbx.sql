{{ config(
    materialized='table',
    pre_hook="{{ dbt_context_engineering.ce_guard_batch(ref('ce_fixture_utterances'), 'utterance_text') }}",
    post_hook="{{ dbt_context_engineering.ce_log_ai_run('classify', model_name='ai_classify', relation=ref('ce_fixture_utterances'), input_column='utterance_text') }}"
) }}
{#- Governed pattern: guard (pre) + ai_classify + log (post), live on Databricks. -#}
select
    utterance_id,
    call_id,
    {{ dbt_context_engineering.ce_classify(
        'utterance_text',
        dbt_context_engineering.ce_prompt('EXAMPLE_signal_classify', 'v3'),
        dbt_context_engineering.ce_schema('EXAMPLE_signal_classify', 'v3')
    ) }} as signal
from {{ ref('ce_fixture_utterances') }}
