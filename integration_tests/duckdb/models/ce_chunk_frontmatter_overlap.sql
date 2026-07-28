{{ config(materialized='table') }}
{#- frontmatter_columns + overlap_tokens>0 together: a sentence duplicated across two adjacent
    chunks (the overlap path in _ce_exploded) must carry identical frontmatter into both. -#}
{{ dbt_context_engineering.ce_chunk(
    relation=ref('ce_split_docs'),
    id_column='sentence_id',
    order_column='sentence_index',
    text_column='sentence_text',
    partition_column='document_id',
    frontmatter_columns=['title', 'citation_url'],
    target_tokens=10,
    overlap_tokens=4,
    join_separator=' '
) }}
