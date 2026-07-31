{{ config(materialized='table') }}

{#- Flatten the structured ce_generate output (a VARIANT object on Snowflake) into typed scalar
    columns via ce_field — the output-normalization pattern. Renders snowflake__ce_field. -#}
select
    {{ dbt_context_engineering.ce_field('result', 'signal') }}   as signal,
    {{ dbt_context_engineering.ce_field('result', 'evidence') }} as evidence
from {{ ref('ce_generate_sf') }}
