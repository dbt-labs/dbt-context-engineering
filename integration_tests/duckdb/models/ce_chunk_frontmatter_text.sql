{{ config(materialized='table') }}
{#- Same as ce_chunk_frontmatter_cols but frontmatter_in_text=True: chunk_text is prefixed with
    a "title: ...\ncitation_url: ...\n---\n" block on every chunk, in addition to the columns. -#}
{{ dbt_context_engineering.ce_chunk(
    relation=ref('ce_split_docs'),
    id_column='sentence_id',
    order_column='sentence_index',
    text_column='sentence_text',
    partition_column='document_id',
    frontmatter_columns=['title', 'citation_url'],
    frontmatter_in_text=true,
    target_tokens=15,
    overlap_tokens=0,
    join_separator=' '
) }}
