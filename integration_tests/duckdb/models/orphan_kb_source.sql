{{ config(materialized='table') }}
{#- var-driven row count (unlike a hardcoded fixture) specifically so this can be rebuilt with a
    row REMOVED entirely, simulating a knowledge_base source deleting a record. See
    orphan_chunks.sql for the same pattern applied to chunk(). -#}
select 'k1' as item_id, 'acme' as account_id, 'first item' as body,
       [1.0, 0.0, 0.0]::float[3] as embedding, timestamp '2026-01-01 00:00' as ts
union all
select 'k2', 'acme', 'second item', [0.0, 1.0, 0.0]::float[3], timestamp '2026-01-02 00:00'
{%- if var('ok_include_k3', true) %}
union all
select 'k3', 'acme', 'third item', [0.0, 0.0, 1.0]::float[3], timestamp '2026-01-03 00:00'
{%- endif %}
