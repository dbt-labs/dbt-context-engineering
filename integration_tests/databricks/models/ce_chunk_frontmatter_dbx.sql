{{ config(materialized='table') }}
{#- Deterministic, no AI: ce_chunk's frontmatter_columns + frontmatter_in_text on Databricks —
    title/citation_url pass through as columns AND get prepended to chunk_text. -#}
{{ dbt_context_engineering.ce_chunk(
    relation=ref('ce_split_docs_dbx'),
    id_column='sentence_id', order_column='sentence_index', text_column='sentence_text',
    partition_column='document_id', frontmatter_columns=['title', 'citation_url'],
    frontmatter_in_text=true, target_tokens=15, join_separator=' '
) }}
