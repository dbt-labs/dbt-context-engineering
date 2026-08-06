{{ config(materialized='table') }}
select
    utterance_id,
    {{ dbt_context_engineering.extract('utterance_text',
        dbt_context_engineering.prompt('EXAMPLE_signal_classify','v3'),
        dbt_context_engineering.schema_def('EXAMPLE_signal_classify','v3')) }} as extracted
from {{ ref('fixture_utterances') }}
