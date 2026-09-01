{{ config(materialized='incremental', unique_key='source_key') }}

{#- Exercises knowledge_base's own version of the orphan gap: a source relation (orphan_kb_source,
    var-driven row count) can drop a row entirely, simulating an upstream deletion. knowledge_base's
    own macro-owned content_hash correctly catches a text/account_key/etc. edit on a source_key
    that still exists, but a source_key that vanishes from its source relation entirely never
    enters ANY delta comparison, the same shape as chunk()'s and attach_metadata()'s own orphan
    gap. Not fixed with deletion logic, surfaced instead: see this model's relationships test in
    schema.yml, against orphan_kb_valid_keys. -#}

{{ dbt_context_engineering.knowledge_base([
    {'relation': ref('orphan_kb_source'), 'source_type': 'item',
     'source_id': 'item_id', 'account_key': 'account_id',
     'text': 'body', 'embedding': 'embedding', 'timestamp': 'ts'}
]) }}
