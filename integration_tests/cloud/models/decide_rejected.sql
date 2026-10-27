{{ config(
    materialized='table',
    enabled=(target.type == 'snowflake' and dbt_context_engineering.decide_available())
) }}

{#- LIVE validation of decide_error on Snowflake: one request Snowflake rejects (a question type
    that does not exist), sent through the engine branch directly because decide()'s own
    validation stops it at compile time. Snowflake reports the failure in-band only with
    return_error_details, so this proves the error reaches decide_error instead of a bare NULL.
    One row, rejected before the model runs. Not a one-label choice: snowflake-decision rejects
    it, but snowflake-decision-fast answers it. -#}
{{ dbt_context_engineering.require_ai_functions_enabled('decide') }}
select
    1 as id,
    {{ dbt_context_engineering.snowflake__decide("'The nightly load failed again'",
        {'topic': {'type': 'pick', 'instructions': 'What is this about?',
                   'criteria': {'pipelines': 'Pipelines failing', 'pricing': 'Cost or price'}}}) }} as d
