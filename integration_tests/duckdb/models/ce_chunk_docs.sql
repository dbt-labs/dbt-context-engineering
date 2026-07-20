{{ config(materialized='table') }}
{#- The full recursive-splitter pattern end to end: split (ce_split_docs) THEN pack (ce_chunk),
    unit = sentence. target_tokens=15 forces doc_1 to span two chunks on the tiny fixture. -#}
{{ dbt_context_engineering.ce_chunk(
    relation=ref('ce_split_docs'),
    id_column='sentence_id',
    order_column='sentence_index',
    text_column='sentence_text',
    partition_column='document_id',
    target_tokens=15,
    overlap_tokens=0,
    join_separator=' '
) }}
