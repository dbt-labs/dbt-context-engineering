{{ config(materialized='table') }}

{#- Flatten the structured ce_generate output (a JSON string on Databricks) into typed scalar
    columns via ce_field — the output-normalization pattern. Renders databricks__ce_field. -#}
select
    {{ dbt_context_engineering.ce_field('result', 'signal') }}   as signal,
    {{ dbt_context_engineering.ce_field('result', 'evidence') }} as evidence
from {{ ref('ce_generate_dbx') }}
