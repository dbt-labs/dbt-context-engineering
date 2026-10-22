{{ config(materialized='table') }}
-- The highest-risk Redshift SQL: pure-SQL brute-force cosine over SUPER arrays (unnest + AT index
-- + aggregate). Query vector is embed() of a literal near-identical to doc 1, so doc 1 must rank #1.
{{ dbt_context_engineering.vector_search(
    relation=ref('rs_embeddings'),
    embedding_column='embedding',
    query_embedding=dbt_context_engineering.embed("'the nightly pipeline keeps failing on load'"),
    top_k=3,
    id_column='id',
    select_columns=['txt']
) }}
