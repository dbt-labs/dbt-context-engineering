{{ config(materialized='incremental', unique_key='source_key') }}

{#- knowledge_base's macro-owned per-arm incremental mechanism. Plain merge on source_key, no
    strategy override, same reasoning as attach_metadata: knowledge_base never invents or
    renumbers source_key, so an incoming key matches at most one stored row.

    built_at is stamped here, not inside knowledge_base, purely so assert_kb_delta can prove an
    untouched row (or an entire untouched source arm) was SKIPPED rather than rewritten with
    identical content. Same trick as chunk_delta/attach_metadata_delta's own built_at column. -#}

with kb as (
    {{ dbt_context_engineering.knowledge_base([
        {'relation': ref('kb_delta_tickets_stg'), 'source_type': 'ticket',
         'source_id': 'ticket_id', 'account_key': 'account_id',
         'text': 'body', 'embedding': 'embedding', 'timestamp': 'created_at',
         'citation_url': 'ticket_url', 'classification': 'category'},
        {'relation': ref('kb_delta_calls_stg'), 'source_type': 'call',
         'source_id': 'call_id', 'account_key': 'account_id',
         'text': 'transcript', 'embedding': 'embedding', 'timestamp': 'call_time'}
    ]) }}
)

select kb.*, cast('{{ run_started_at }}' as timestamp) as built_at
from kb
