{{ config(materialized='table') }}
{#- AI_COMPLETE with structured output (response_format object). -#}
select
    utterance_id,
    {{ dbt_context_engineering.ce_generate(
        'utterance_text',
        dbt_context_engineering.ce_prompt('EXAMPLE_signal_classify', 'v3'),
        dbt_context_engineering.ce_schema('EXAMPLE_signal_classify', 'v3')
    ) }} as result
from {{ ref('ce_fixture_utterances') }}
