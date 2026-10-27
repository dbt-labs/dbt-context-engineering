{{ config(materialized='table') }}
{#- Brute-force cosine similarity search (vendor function per engine): top-3 utterances closest
    to a query, where the query is embedded with the SAME model as the corpus. -#}
{{ dbt_context_engineering.vector_search(
    relation=ref('embeddings'),
    embedding_column='embedding',
    query_embedding=dbt_context_engineering.embed("'pipeline keeps breaking on the nightly load'"),
    top_k=3,
    id_column='utterance_id',
    select_columns=['call_id', 'utterance_text']
) }}
