{{ config(materialized='table') }}

{#- Flatten the structured generate output (a VARIANT object on Snowflake) into typed scalar
    columns via field — the output-normalization pattern. Renders snowflake__field. -#}
select
    {{ dbt_context_engineering.field('result', 'signal') }}   as signal,
    {{ dbt_context_engineering.field('result', 'evidence') }} as evidence
from {{ ref('generate_sf') }}
