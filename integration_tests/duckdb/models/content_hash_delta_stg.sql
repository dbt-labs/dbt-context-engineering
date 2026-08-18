{{ config(materialized = 'view') }}

{#- content_hash must be a materialized COLUMN somewhere upstream of the embedding model, not a
    same-SELECT alias computed and filtered on in one query (BigQuery won't resolve that, the same
    trap chunk.sql's own comments already document) and not something guard_batch/log_ai_run can
    meter unless their `relation` actually carries the column the filter references. This staging
    step is that column's one real home; content_hash_delta.sql and its guard_batch/log_ai_run
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
