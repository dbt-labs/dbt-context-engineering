{{ config(materialized='table') }}
{#- Brute-force vector_cosine_similarity search: top-3 closest utterances to a query. -#}
{{ dbt_context_engineering.vector_search(
    relation=ref('embeddings_dbx'),
    embedding_column='embedding',
    query_embedding=dbt_context_engineering.embed("'pipeline keeps breaking on the nightly load'"),
    top_k=3,
    id_column='utterance_id',
    select_columns=['call_id', 'utterance_text']
) }}
