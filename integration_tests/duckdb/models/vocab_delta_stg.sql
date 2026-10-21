{{ config(materialized='view') }}
{#- Input relation for the vocabulary delta stand-in: id, text and a materialized content_hash,
    the column vocabulary_delta_predicate compares (ADR-0023). -#}
select utterance_id, utterance_text, {{ dbt_context_engineering.content_hash('utterance_text') }} as content_hash
from {{ ref('fixture_utterances') }}
