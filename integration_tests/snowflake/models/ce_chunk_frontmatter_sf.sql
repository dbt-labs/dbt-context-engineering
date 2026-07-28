{{ config(materialized='table') }}
{#- Deterministic, zero-AI-cost: validates ce_chunk's frontmatter_columns + frontmatter_in_text
    on real Snowflake — title/citation_url pass through as columns AND get prepended to
    chunk_text on every chunk. -#}
{{ dbt_context_engineering.ce_chunk(
    relation=ref('ce_split_docs_sf'),
    id_column='sentence_id',
    order_column='sentence_index',
    text_column='sentence_text',
    partition_column='document_id',
    frontmatter_columns=['title', 'citation_url'],
    frontmatter_in_text=true,
    target_tokens=15,
    join_separator=' '
) }}
