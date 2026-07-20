{{ config(materialized='table') }}
{#- split -> pack pipeline: ce_chunk over ce_split_docs_dbx (unit=sentence). -#}
{{ dbt_context_engineering.ce_chunk(
    relation=ref('ce_split_docs_dbx'),
    id_column='sentence_id',
    order_column='sentence_index',
    text_column='sentence_text',
    partition_column='document_id',
    target_tokens=15,
    join_separator=' '
) }}
