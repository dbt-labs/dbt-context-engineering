-- Exact chunk shape for every data-shape edge case at target_tokens=40, overlap=0.
-- Returns rows only on mismatch.
--
-- adr_ex is the load-bearing pair. ADR-0002's worked example diagrams the same 18/17/25/12/30
-- token units packing into THREE chunks of 35/37/30, none over the 40 budget, by closing a chunk
-- before admitting the unit that would exceed it. The implementation assigns chunks with
-- floor(cum_before / step), which has no lookahead, so the crossing unit joins the CURRENT chunk
-- and both chunks land over budget. These are the produced values, identical on all four engines.
--
-- oversize pins that the overshoot is bounded by the largest UNIT, not by "one small unit":
-- a 400-token unit against a 40-token budget yields a 405-token chunk. No packing strategy can
-- avoid this while units stay atomic, which is why exceeds_target is a flag and not an error.
with produced as (
    select
        partition_key,
        chunk_seq,
        n_source_rows,
        cast(token_estimate as {{ dbt.type_int() }}) as token_estimate,
        exceeds_target,
        length(chunk_text) as text_len,
        {{ t_arr_csv('source_rows') }} as rows_csv
    from {{ ref('chunk_edges') }}
),
expected as (
    select 'adr_ex' as partition_key, 1 as chunk_seq, 3 as n_source_rows, 61 as token_estimate, true as exceeds_target, 242 as text_len, 'e1,e2,e3' as rows_csv
    union all select 'adr_ex',    2, 2,  43, true,  169, 'e4,e5'
    union all select 'all_null',  1, 2,   1, false,   1, 'z1,z2'
    union all select 'empty_mid', 1, 3,  21, false,  82, 'm1,m2,m3'
    union all select 'null_mid',  1, 3,  21, false,  82, 'n1,n2,n3'
    union all select 'oversize',  1, 2, 405, true,  1617, 'o1,o2'
    union all select 'oversize',  2, 1,   4, false,  16, 'o3'
    union all select 'single',    1, 1,  10, false,  40, 'i1'
)
select
    coalesce(p.partition_key, e.partition_key) as partition_key,
    coalesce(p.chunk_seq, e.chunk_seq)         as chunk_seq,
    p.n_source_rows  as produced_rows,    e.n_source_rows  as expected_rows,
    p.token_estimate as produced_tokens,  e.token_estimate as expected_tokens,
    p.exceeds_target as produced_exceeds, e.exceeds_target as expected_exceeds,
    p.text_len       as produced_len,     e.text_len       as expected_len,
    p.rows_csv       as produced_csv,     e.rows_csv       as expected_csv
from produced p
full outer join expected e
    on p.partition_key = e.partition_key and p.chunk_seq = e.chunk_seq
where p.n_source_rows  is distinct from e.n_source_rows
   or p.token_estimate is distinct from e.token_estimate
   or p.exceeds_target is distinct from e.exceeds_target
   or p.text_len       is distinct from e.text_len
   or p.rows_csv       is distinct from e.rows_csv
