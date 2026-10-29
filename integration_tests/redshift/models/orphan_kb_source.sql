{{ config(materialized='table') }}
{#- var-driven row count (unlike a hardcoded fixture) specifically so this can be rebuilt with a
    row REMOVED entirely, simulating a knowledge_base source deleting a record. See
    orphan_chunks.sql for the same pattern applied to chunk(). Reuses embeddings' already-paid-for
    vectors, no new AI spend. -#}
select
    utterance_id as item_id,
    call_id as account_id,
    utterance_text as body,
    embedding,
    cast('2026-01-01 00:00:00' as {{ dbt.type_timestamp() }}) as ts
from {{ ref('embeddings') }}
where cast(utterance_id as {{ dbt.type_string() }}) in ('1', '2'{{ ", '3'" if var('ok_include_k3', true) else "" }})
