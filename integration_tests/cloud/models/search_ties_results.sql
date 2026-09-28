{{ config(materialized='table') }}

{#- top_k=2 over a corpus where ranks 2 to 4 tie on score, so the id_column tiebreaker decides the
    returned second row. See assert_vector_search_tiebreak. -#}
{{ dbt_context_engineering.vector_search(
    relation=ref('search_ties_corpus'),
    embedding_column='embedding',
    query_embedding=t_vec([1.0, 0.0, 0.0]),
    top_k=2,
    id_column='doc_id'
) }}
