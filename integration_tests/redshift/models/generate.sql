{{ config(materialized='table') }}
{#- generate() dispatched per engine, with structured output (output_schema). -#}
select
    utterance_id,
    {{ dbt_context_engineering.generate(
        'utterance_text',
        dbt_context_engineering.prompt('EXAMPLE_signal_classify', 'v3'),
        dbt_context_engineering.schema_def('EXAMPLE_signal_classify', 'v3')
    ) }} as result
from {{ ref('fixture_utterances') }}
