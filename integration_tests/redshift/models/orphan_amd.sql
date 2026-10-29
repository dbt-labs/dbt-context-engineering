{{ config(materialized='incremental', unique_key='chunk_id') }}

{#- Exercises attach_metadata's own version of the chunk_id orphaning gap, same shape as
    orphan_embeddings: chunks_relation (orphan_chunks, var-driven target_tokens) can be re-chunked
    with a different config, dropping a chunk_id that used to exist. attach_metadata's own
    macro-owned content_hash correctly catches a metadata-only or text-only edit on a chunk_id
    that still exists, but a chunk_id that vanishes from chunks_relation entirely never enters
    ANY delta comparison, since incremental_delta_predicate only ever looks at keys PRESENT in the
    current batch. Not fixed with deletion logic (deliberately avoided elsewhere, see
    orphan_embeddings.sql), surfaced instead: see this model's relationships test in schema.yml. -#}

{{ dbt_context_engineering.attach_metadata(
    chunks_relation=ref('orphan_chunks'),
    metadata_relation=ref('fixture_calls'),
    metadata_key_column='call_id',
    metadata_columns=['customer', 'participants', 'recording_url']
) }}
