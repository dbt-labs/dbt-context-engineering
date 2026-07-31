{{ config(materialized='table') }}
{#- ce_chunk (unmodified) -> ce_attach_metadata, default in_text=False: title/citation_url
    join on from the seed and pass through as columns; chunk_text is untouched (identical to
    ce_chunk_docs_dbx). -#}
{{ dbt_context_engineering.ce_attach_metadata(
    chunks_relation=ref('ce_chunk_docs_dbx'),
    metadata_relation=ref('ce_fixture_documents'),
    metadata_key_column='document_id',
    metadata_columns=['title', 'citation_url']
) }}
