{{ config(materialized='table') }}

{#- Same tied corpus as search_ties_results, but top_k=4 returns every row, so no cutoff falls
    inside the three-way tie. That isolates the ordering guarantee from the cutoff guarantee: here
    the ORDER BY score desc, id_column governs the whole result on every engine, BigQuery
    included, so the full ordering is deterministic. search_ties_results covers the other half,
    where the cutoff sits inside the tie and BigQuery diverges. -#}
{{ dbt_context_engineering.vector_search(
    relation=ref('search_ties_corpus'),
    embedding_column='embedding',
    query_embedding=t_vec([1.0, 0.0, 0.0]),
    top_k=4,
    id_column='doc_id'
) }}
