{{ config(materialized='table') }}
{#- ai_query embedding serving endpoint — a vector column next to each row. -#}
select
    utterance_id,
    call_id,
    utterance_text,
    {{ dbt_context_engineering.ce_embed('utterance_text') }} as embedding
from {{ ref('ce_fixture_utterances') }}
