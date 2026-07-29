{{ config(materialized='table') }}
{#- Layer-1 splitter (deterministic, no AI) over the document seed. -#}
{{ dbt_context_engineering.ce_split_sentences(
    relation=ref('ce_fixture_documents'),
    id_column='document_id',
    text_column='document_text'
) }}
