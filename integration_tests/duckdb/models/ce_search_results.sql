{{ config(materialized='table') }}

{#- Brute-force cosine search for query [1,0,0] over ce_search_corpus (top 2). -#}
{{ dbt_context_engineering.ce_vector_search(
    relation=ref('ce_search_corpus'),
    embedding_column='embedding',
    query_embedding='[1.0, 0.0, 0.0]::float[3]',
    top_k=2,
    id_column='doc_id'
) }}
