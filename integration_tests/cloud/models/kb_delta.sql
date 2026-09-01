{{ config(materialized='incremental', unique_key='source_key') }}

{#- knowledge_base's macro-owned per-arm incremental mechanism. Plain merge on source_key, no
    strategy override, same reasoning as attach_metadata: knowledge_base never invents or
    renumbers source_key, so an incoming key matches at most one stored row.

    built_at is stamped here, not inside knowledge_base, purely so assert_kb_delta can prove an
    untouched row (or an entire untouched source arm) was SKIPPED rather than rewritten with
    identical content. -#}

with kb as (
    {{ dbt_context_engineering.knowledge_base([
        {'relation': ref('kb_delta_tickets_stg'), 'source_type': 'ticket',
         'source_id': 'synth_id', 'account_key': 'call_id',
         'text': 'utterance_text', 'embedding': 'embedding',
         'timestamp': "cast('2026-01-01 00:00:00' as " ~ dbt.type_timestamp() ~ ")"},
        {'relation': ref('kb_delta_calls_stg'), 'source_type': 'call',
         'source_id': 'synth_id', 'account_key': 'call_id',
         'text': 'utterance_text', 'embedding': 'embedding',
         'timestamp': "cast('2026-01-01 00:00:00' as " ~ dbt.type_timestamp() ~ ")"}
    ]) }}
)

select kb.*, cast('{{ run_started_at }}' as {{ dbt.type_timestamp() }}) as built_at
from kb
