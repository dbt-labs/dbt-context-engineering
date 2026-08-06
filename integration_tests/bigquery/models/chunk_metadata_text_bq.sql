{{ config(materialized='table') }}
{#- Same as chunk_metadata_cols_bq but in_text=True: chunk_text is prefixed with a
    "title: ...\ncitation_url: ...\n---\n" block on every chunk, in addition to the columns. -#}
{{ dbt_context_engineering.attach_metadata(
    chunks_relation=ref('chunk_docs_bq'),
    metadata_relation=ref('fixture_documents'),
    metadata_key_column='document_id',
    metadata_columns=['title', 'citation_url'],
    in_text=true
) }}
