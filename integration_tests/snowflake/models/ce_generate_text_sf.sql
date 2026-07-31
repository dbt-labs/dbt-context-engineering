{{ config(
    materialized='table',
    pre_hook="{{ dbt_context_engineering.ce_guard_batch(ref('ce_fixture_utterances'), 'utterance_text') }}"
) }}

{#- LIVE validation of ce_text: unstructured ce_generate (no output_schema) wrapped in ce_text, which
    normalizes the plain-text return per engine (BigQuery STRUCT `.result` vs Snowflake/Databricks
    string). 2 rows to bound AI cost. Non-empty output asserted by assert_generate_text_sf. -#}
select
    utterance_id,
    {{ dbt_context_engineering.ce_text(
        dbt_context_engineering.ce_generate('utterance_text',
            dbt_context_engineering.ce_prompt('EXAMPLE_signal_classify', 'v3'))
    ) }} as txt
from {{ ref('ce_fixture_utterances') }}
where utterance_id <= 2
