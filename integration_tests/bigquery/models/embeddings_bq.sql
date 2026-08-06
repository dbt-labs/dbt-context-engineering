{{ config(materialized='table') }}
select
    utterance_id, call_id, utterance_text,
    {{ dbt_context_engineering.embed('utterance_text') }} as embedding
from {{ ref('fixture_utterances') }}
