{{ config(materialized = 'view') }}

{#- content_hash is a real column here, not a same-SELECT alias, since guard_batch/log_ai_run's
    `relation` needs an actual content_hash column to filter on. content_hash_delta.sql and its
    hooks both point at THIS relation, never at fixture_utterances directly. -#}

with source as (
    select
        utterance_id,
        case when utterance_id = {{ var('ch_edit_id', -1) }}
             then utterance_text || ' (edited)'
             else utterance_text
        end as body
    from {{ ref('fixture_utterances') }}
)
select
    utterance_id,
    body,
    {{ dbt_context_engineering.content_hash('body') }} as content_hash
from source
