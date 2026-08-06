{{ config(materialized='table') }}
{#- chunk (unmodified) -> attach_metadata, default in_text=False: title/citation_url
    join on from the seed and pass through as columns; chunk_text is untouched (identical to
    chunk_docs_sf). -#}
{{ dbt_context_engineering.attach_metadata(
    chunks_relation=ref('chunk_docs_sf'),
    metadata_relation=ref('fixture_documents'),
    metadata_key_column='document_id',
    metadata_columns=['title', 'citation_url']
) }}
