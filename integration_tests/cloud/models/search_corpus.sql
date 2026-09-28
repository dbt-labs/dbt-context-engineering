{{ config(materialized='table') }}

{#- Tiny synthetic embedding corpus (3-dim) for validating vector_search against known vectors.
    Query [1,0,0] should rank d1 (identical) first and d3 (near) second; d2 and d4 are orthogonal.
    Literals go through t_vec so the same fixture builds on all four engines. -#}
select 'd1' as doc_id, {{ t_vec([1.0, 0.0, 0.0]) }} as embedding
union all select 'd2', {{ t_vec([0.0, 1.0, 0.0]) }}
union all select 'd3', {{ t_vec([0.9, 0.1, 0.0]) }}
union all select 'd4', {{ t_vec([0.0, 0.0, 1.0]) }}
