{{ config(materialized='table') }}
{#- knowledge_base heterogeneous-timestamp union (#8): source A's timestamp expression is a DATE,
    source B's is a TIMESTAMP. knowledge_base casts both to a common type so the UNION runs on strict
    engines (BigQuery rejects a UNION whose Nth columns differ in type); without that cast this build
    would fail. Both sources derive from the live embeddings model so the embedding column type is real.
    LIVE-VALIDATION DEFERRED. -#}
{% set ts = dbt.type_timestamp() %}
{{ dbt_context_engineering.knowledge_base([
    {'relation': ref('embeddings'), 'source_type': 'date_src',
     'source_id': 'utterance_id', 'account_key': 'call_id',
     'text': 'utterance_text', 'embedding': 'embedding',
     'timestamp': "cast('2026-01-03' as date)"},
    {'relation': ref('embeddings'), 'source_type': 'ts_src',
     'source_id': 'utterance_id', 'account_key': 'call_id',
     'text': 'utterance_text', 'embedding': 'embedding',
     'timestamp': "cast('2026-01-01 10:00:00' as " ~ ts ~ ")"}
]) }}
