{{ config(materialized='table') }}
{#- Layer-1 splitter (deterministic, no AI) over the document seed. -#}
{{ dbt_context_engineering.split_sentences(
    relation=ref('fixture_documents'),
    id_column='document_id',
    text_column='document_text'
) }}
