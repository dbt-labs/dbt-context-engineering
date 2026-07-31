{{ config(materialized='table') }}

{#- Flatten ce_extract's structured output to scalars via ce_field, joined to the source text so
    evidence groundedness can be asserted (assert_extract_grounded_dbx). The per-engine result
    shape (Snowflake VARIANT object — unwrapped from AI_EXTRACT's :response envelope in the wrapper;
    Databricks JSON string; BigQuery STRUCT) is read uniformly by ce_field. LIVE-VALIDATION DEFERRED. -#}
select
    e.utterance_id,
    u.utterance_text,
    {{ dbt_context_engineering.ce_field('e.extracted', 'signal') }}   as signal,
    {{ dbt_context_engineering.ce_field('e.extracted', 'evidence') }} as evidence
from {{ ref('ce_extract_dbx') }} e
join {{ ref('ce_fixture_utterances') }} u on e.utterance_id = u.utterance_id
