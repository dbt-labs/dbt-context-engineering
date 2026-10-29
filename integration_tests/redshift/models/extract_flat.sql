{{ config(materialized='table') }}

{#- Flatten extract's structured output to scalars via field, joined to the source text so
    evidence groundedness can be asserted (assert_extract_grounded). The per-engine result
    shape (Snowflake VARIANT object; Databricks JSON string; BigQuery STRUCT) is read uniformly by
    field. LIVE-VALIDATION DEFERRED. -#}
select
    e.utterance_id,
    u.utterance_text,
    {{ dbt_context_engineering.field('e.extracted', 'signal') }}   as signal,
    {{ dbt_context_engineering.field('e.extracted', 'evidence') }} as evidence
from {{ ref('extract') }} e
join {{ ref('fixture_utterances') }} u on e.utterance_id = u.utterance_id
