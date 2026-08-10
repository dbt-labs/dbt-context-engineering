{{ config(materialized='table') }}
{#- split_sentences over the adversarial docs; assert_split_adversarial_dbx checks the golden set. -#}
{{ dbt_context_engineering.split_sentences(
    relation=ref('adversarial_docs_dbx'),
    id_column='document_id',
    text_column='document_text'
) }}
