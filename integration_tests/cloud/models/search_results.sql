{{ config(materialized='table') }}

{#- Brute-force cosine search for query [1,0,0] over search_corpus (top 2). -#}
{{ dbt_context_engineering.vector_search(
    relation=ref('search_corpus'),
    embedding_column='embedding',
    query_embedding=t_vec([1.0, 0.0, 0.0]),
    top_k=2,
    id_column='doc_id'
) }}
