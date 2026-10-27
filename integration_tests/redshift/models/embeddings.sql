{{ config(materialized='table') }}
{#- embed() dispatched per engine (Snowflake AI_EMBED / Databricks ai_query serving endpoint /
    BigQuery AI.EMBED) — a vector column next to each row. -#}
select
    utterance_id,
    call_id,
    utterance_text,
    {{ dbt_context_engineering.embed('utterance_text') }} as embedding
from {{ ref('fixture_utterances') }}
