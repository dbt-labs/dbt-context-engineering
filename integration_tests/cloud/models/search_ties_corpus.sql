{{ config(materialized='table') }}

{#- Corpus that forces a TIE at the top_k cutoff, to exercise vector_search's tiebreaker.
    Query [1,0,0]: d1 is identical (score 1.0), and tie_a/tie_b/tie_c share the SAME embedding so
    they tie exactly on score. With top_k=2 the cutoff falls inside that three-way tie, and the
    id_column tiebreaker must resolve it to the lowest id ('tie_a'), the same on every run. Rows
    are deliberately listed out of id order so a missing tiebreaker can surface. -#}
select 'd1' as doc_id, {{ t_vec([1.0, 0.0, 0.0]) }} as embedding
union all select 'tie_c', {{ t_vec([0.5, 0.5, 0.0]) }}
union all select 'tie_a', {{ t_vec([0.5, 0.5, 0.0]) }}
union all select 'tie_b', {{ t_vec([0.5, 0.5, 0.0]) }}
