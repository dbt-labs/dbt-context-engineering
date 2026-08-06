{{ config(materialized='table') }}
{#- ai_query with structured output (responseFormat) + modelParameters max_tokens cap. -#}
select
    utterance_id,
    {{ dbt_context_engineering.generate(
        'utterance_text',
        dbt_context_engineering.prompt('EXAMPLE_signal_classify', 'v3'),
        dbt_context_engineering.schema_def('EXAMPLE_signal_classify', 'v3')
    ) }} as result
from {{ ref('fixture_utterances') }}
