{{ config(materialized='table') }}
{#- One structured generate call whose schema carries integer, number and boolean fields. -#}
select
    utterance_id,
    {{ dbt_context_engineering.generate(
        'utterance_text',
        dbt_context_engineering.prompt('EXAMPLE_typed_cast', 'v1'),
        dbt_context_engineering.schema_def('EXAMPLE_typed_cast', 'v1')
    ) }} as result
from {{ ref('fixture_utterances') }}
where utterance_id = 1
