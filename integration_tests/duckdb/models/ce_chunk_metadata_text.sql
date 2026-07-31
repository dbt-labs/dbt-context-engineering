{{ config(materialized='table') }}
{#- Same as ce_chunk_metadata_cols but in_text=True: chunk_text is prefixed with a
    "title: ...\ncitation_url: ...\n---\n" block on every chunk, in addition to the columns. -#}
{{ dbt_context_engineering.ce_attach_metadata(
    chunks_relation=ref('ce_chunk_docs'),
    metadata_relation=ref('ce_fixture_documents'),
    metadata_key_column='document_id',
    metadata_columns=['title', 'citation_url'],
    in_text=true
) }}
