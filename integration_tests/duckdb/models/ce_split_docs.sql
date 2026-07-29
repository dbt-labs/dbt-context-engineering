{{ config(materialized='table') }}
{#- Layer-1 splitter: ce_fixture_documents -> one row per sentence. Feeds ce_chunk (ce_chunk_docs). -#}
{{ dbt_context_engineering.ce_split_sentences(
    relation=ref('ce_fixture_documents'),
    id_column='document_id',
    text_column='document_text'
) }}
