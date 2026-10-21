{{ config(materialized='table') }}

{#- Stand-in for vocabulary_decide's output on the classify fallback path: labels only, no
    confidence. 1 is an active term (unscored), 2 is not in the vocabulary (needs_review). -#}
select 1 as utterance_id, cast(null as varchar) as content_hash, 'call_topics' as vocabulary_name,
       'v1' as vocabulary_version, 'call_topics@v1/classify' as vocabulary_key, 'classify' as method,
       cast(null as varchar) as decision, 'pricing' as classified_term, current_timestamp as decided_at
union all
select 2, null, 'call_topics', 'v1', 'call_topics@v1/classify', 'classify', null, 'not_a_term', current_timestamp
