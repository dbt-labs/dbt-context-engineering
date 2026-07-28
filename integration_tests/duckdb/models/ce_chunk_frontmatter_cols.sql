{{ config(materialized='table') }}
{#- frontmatter_columns, default frontmatter_in_text=False: title/citation_url pass through as
    columns; chunk_text is untouched (identical to ce_chunk_docs). -#}
{{ dbt_context_engineering.ce_chunk(
    relation=ref('ce_split_docs'),
    id_column='sentence_id',
    order_column='sentence_index',
    text_column='sentence_text',
    partition_column='document_id',
    frontmatter_columns=['title', 'citation_url'],
    target_tokens=15,
    overlap_tokens=0,
    join_separator=' '
) }}
