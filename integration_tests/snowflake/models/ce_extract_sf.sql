{{ config(materialized='table') }}
{#- AI_EXTRACT with a JSON-schema responseFormat. -#}
select
    utterance_id,
    {{ dbt_context_engineering.ce_extract(
        'utterance_text',
        dbt_context_engineering.ce_prompt('EXAMPLE_signal_classify', 'v3'),
        dbt_context_engineering.ce_schema('EXAMPLE_signal_classify', 'v3')
    ) }} as extracted
from {{ ref('ce_fixture_utterances') }}
