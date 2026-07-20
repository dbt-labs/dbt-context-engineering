{{ config(materialized='table') }}
{#- AI_EMBED — a VECTOR column next to each row. -#}
select
    utterance_id,
    call_id,
    utterance_text,
    {{ dbt_context_engineering.ce_embed('utterance_text') }} as embedding
from {{ ref('ce_fixture_utterances') }}
