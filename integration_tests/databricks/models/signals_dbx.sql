{{ config(
    materialized='table',
    pre_hook="{{ dbt_context_engineering.guard_batch(ref('fixture_utterances'), 'utterance_text') }}",
    post_hook="{{ dbt_context_engineering.log_ai_run('classify', model_name='ai_classify', relation=ref('fixture_utterances'), input_column='utterance_text') }}"
) }}
{#- Governed pattern: guard (pre) + ai_classify + log (post), live on Databricks. -#}
select
    utterance_id,
    call_id,
    {{ dbt_context_engineering.classify(
        'utterance_text',
        dbt_context_engineering.prompt('EXAMPLE_signal_classify', 'v3'),
        dbt_context_engineering.schema_def('EXAMPLE_signal_classify', 'v3')
    ) }} as signal
from {{ ref('fixture_utterances') }}
