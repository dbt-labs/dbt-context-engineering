{{ config(materialized='table') }}

{#- Flatten the structured generate output (Snowflake VARIANT object, Databricks JSON string,
    BigQuery STRUCT) into typed scalar columns via field — the output-normalization pattern. -#}
select
    {{ dbt_context_engineering.field('result', 'signal') }}   as signal,
    {{ dbt_context_engineering.field('result', 'evidence') }} as evidence
from {{ ref('generate') }}
