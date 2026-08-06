{{ config(materialized='table') }}
{#- AI_EMBED — a VECTOR column next to each row. -#}
select
    utterance_id,
    call_id,
    utterance_text,
    {{ dbt_context_engineering.embed('utterance_text') }} as embedding
from {{ ref('fixture_utterances') }}
