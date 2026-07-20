{{ config(materialized='table') }}

{#- Tiny synthetic embedding corpus (3-dim unit-ish vectors) for validating ce_vector_search.
    Query [1,0,0] should rank d1 (identical) then d3 (near) top; d2/d4 orthogonal. -#}
select 'd1' as doc_id, [1.0, 0.0, 0.0]::float[3] as embedding
union all select 'd2', [0.0, 1.0, 0.0]::float[3]
union all select 'd3', [0.9, 0.1, 0.0]::float[3]
union all select 'd4', [0.0, 0.0, 1.0]::float[3]
