{{ config(materialized='table') }}
{#- Layer-1 splitter: fixture_documents -> one row per sentence. Feeds chunk (chunk_docs). -#}
{{ dbt_context_engineering.split_sentences(
    relation=ref('fixture_documents'),
    id_column='document_id',
    text_column='document_text'
) }}
