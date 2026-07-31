{{ config(materialized='table') }}

{#- Validates the DEFAULT (JSON-string) path of ce_field + ce_text deterministically. Cloud
    engines return other shapes (VARIANT / STRUCT) — those branches are LIVE-VALIDATION DEFERRED —
    but the default path mirrors a JSON-string result (the Databricks shape) and runs on duckdb. -#}
with raw as (
    select 'e1' as id, '{"signal": "pain_point", "evidence": "keeps breaking"}' as result
    union all
    select 'e2' as id, '{"signal": "objection", "evidence": "pricing is higher"}' as result
)
select
    id,
    {{ dbt_context_engineering.ce_field('result', 'signal') }}   as signal,
    {{ dbt_context_engineering.ce_field('result', 'evidence') }} as evidence,
    {{ dbt_context_engineering.ce_text('result') }}             as raw_text
from raw
