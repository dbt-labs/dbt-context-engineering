{{ config(enabled = var('gate_probe', none) == 'vocabulary_skew', materialized = 'table') }}

{#- Stand-in for a decided relation built against an older vocabulary version (v0) than the labels
    model reads (v1). Selected only with probe_vocabulary_skew. -#}
select 1 as utterance_id, cast(null as varchar) as content_hash, 'call_topics' as vocabulary_name,
       'v0' as vocabulary_version, 'call_topics@v0/decide' as vocabulary_key, 'decide' as method,
       cast(null as varchar) as decision, cast(null as varchar) as classified_term,
       current_timestamp as decided_at
