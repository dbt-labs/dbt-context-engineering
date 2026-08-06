{{ config(materialized='table') }}
{#- ai_query embedding serving endpoint — a vector column next to each row. -#}
select
    utterance_id,
    call_id,
    utterance_text,
    {{ dbt_context_engineering.embed('utterance_text') }} as embedding
from {{ ref('fixture_utterances') }}
