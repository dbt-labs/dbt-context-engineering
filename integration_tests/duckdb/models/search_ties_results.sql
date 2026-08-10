{{ config(materialized='table') }}

{#- top_k=2 over a corpus where ranks 2-4 tie on score; the id_column tiebreaker must make the
    returned second row deterministic. See assert_vector_search_tiebreak. -#}
{{ dbt_context_engineering.vector_search(
    relation=ref('search_ties_corpus'),
    embedding_column='embedding',
    query_embedding='[1.0, 0.0, 0.0]::float[3]',
    top_k=2,
    id_column='doc_id'
) }}
