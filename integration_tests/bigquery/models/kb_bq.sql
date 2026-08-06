{{ config(materialized='table') }}

{#- Multi-source union exercise for knowledge_base on this warehouse: two logical sources over
    the same embedded fixture (source_type distinguishes them) -> a 20-row mart carrying both
    source types with lineage. knowledge_base is pure portable SQL (union + common-shape casts,
    no per-engine dispatch), so this is a liveness/shape check that the union + normalization run on
    the real warehouse. account_key = call_id; ts is a fixed literal (the fixture has no timestamp). -#}
{{ dbt_context_engineering.knowledge_base([
    {'relation': ref('embeddings_bq'), 'source_type': 'call',
     'source_id': 'utterance_id', 'account_key': 'call_id',
     'text': 'utterance_text', 'embedding': 'embedding',
     'timestamp': "cast('2026-01-01 00:00:00' as " ~ dbt.type_timestamp() ~ ")"},
    {'relation': ref('embeddings_bq'), 'source_type': 'ticket',
     'source_id': 'utterance_id', 'account_key': 'call_id',
     'text': 'utterance_text', 'embedding': 'embedding',
     'timestamp': "cast('2026-01-01 00:00:00' as " ~ dbt.type_timestamp() ~ ")"}
]) }}
