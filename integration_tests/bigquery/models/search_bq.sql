{{ config(materialized='table') }}
{{ dbt_context_engineering.vector_search(
    relation=ref('embeddings_bq'), embedding_column='embedding',
    query_embedding=dbt_context_engineering.embed("'pipeline keeps breaking on the nightly load'"),
    top_k=3, id_column='utterance_id', select_columns=['call_id','utterance_text']
) }}
