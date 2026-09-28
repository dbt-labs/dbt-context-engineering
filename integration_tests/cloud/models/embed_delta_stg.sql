{{ config(materialized = 'view') }}

{#- Two-phase source for embed_delta. ed_edit_id defaults to -1, the unedited 10-row baseline.
    Setting it to an utterance_id rewrites exactly that row's text, which changes exactly that
    row's content_hash and nothing else.

    content_hash is a real column rather than a same-SELECT alias, because guard_batch and
    log_ai_run take a `relation` and need an actual column to filter on. -#}

with source as (
    select
        utterance_id,
        case when utterance_id = {{ var('ed_edit_id', -1) }}
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
