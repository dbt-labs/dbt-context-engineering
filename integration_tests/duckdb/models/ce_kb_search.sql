{{ config(materialized='table') }}
{#- "Everything about account acme" — cross-source search over the KB, account-scoped, top 2. -#}
{{ dbt_context_engineering.ce_vector_search(
    relation=ref('ce_kb'),
    embedding_column='embedding',
    query_embedding='[1.0, 0.0, 0.0]::float[3]',
    top_k=2,
    id_column='source_id',
    select_columns=['source_type', 'account_key'],
    filter="account_key = 'acme'"
) }}
