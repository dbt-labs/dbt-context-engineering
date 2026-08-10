{{ config(materialized='table') }}

{#- Corpus that forces a TIE at the top_k cutoff, to exercise vector_search's tiebreaker (finding #10).
    Query [1,0,0]: d1 is identical (score 1.0); tie_a/tie_b/tie_c share the SAME embedding, so they
    tie exactly on score. With top_k=2 the cutoff falls inside that three-way tie — the id_column
    tiebreaker must resolve it deterministically to the lowest id ('tie_a'), the same on every run
    and engine. Rows deliberately listed out of id order so a missing tiebreaker can surface. -#}
select 'd1' as doc_id, [1.0, 0.0, 0.0]::float[3] as embedding
union all select 'tie_c', [0.5, 0.5, 0.0]::float[3]
union all select 'tie_a', [0.5, 0.5, 0.0]::float[3]
union all select 'tie_b', [0.5, 0.5, 0.0]::float[3]
