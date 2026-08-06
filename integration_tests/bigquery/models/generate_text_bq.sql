{{ config(
    materialized='table',
    pre_hook="{{ dbt_context_engineering.guard_batch(ref('fixture_utterances'), 'utterance_text') }}"
) }}

{#- LIVE validation of text: unstructured generate (no output_schema) wrapped in text, which
    normalizes the plain-text return per engine (BigQuery STRUCT `.result` vs Snowflake/Databricks
    string). 2 rows to bound AI cost. Non-empty output asserted by assert_generate_text_bq. -#}
select
    utterance_id,
    {{ dbt_context_engineering.text(
        dbt_context_engineering.generate('utterance_text',
            dbt_context_engineering.prompt('EXAMPLE_signal_classify', 'v3'))
    ) }} as txt
from {{ ref('fixture_utterances') }}
where utterance_id <= 2
