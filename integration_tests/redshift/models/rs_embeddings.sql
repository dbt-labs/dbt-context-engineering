{{ config(materialized='table') }}
-- embed -> json_parse(json_extract_path_text(json_serialize(ce_embed(object('inputText', ...))),'embedding'))
-- (parser-safe extraction; Redshift rejects dot-nav on a function result). embedding_dimension ->
-- get_array_length; content_hash -> sha2(x,256). One embed call per row.
with e as (
    select id, txt, {{ dbt_context_engineering.embed('txt') }} as embedding
    from {{ ref('rs_docs') }}
)
select
    id,
    txt,
    embedding,
    {{ dbt_context_engineering.embedding_dimension('embedding') }} as dim,
    {{ dbt_context_engineering.content_hash('txt') }}             as content_hash
from e
