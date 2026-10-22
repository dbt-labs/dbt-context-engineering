-- LIVE validation of embed + the pure-SQL SUPER-array cosine (redshift__vector_search). The query
-- text is near-identical to doc 1, so it must rank #1; exactly top_k=3 rows; scores in [-1, 1] and
-- non-increasing by rank. Fail rows only.
with r as (
    select id, score, row_number() over (order by score desc) as rn
    from {{ ref('rs_search') }}
)
select 'wrong_count' as issue
from (select count(*) as n from r) c
where c.n <> 3
union all
select 'wrong_top_hit' as issue
from r where rn = 1 and id <> 1
union all
select 'score_out_of_range' as issue
from r where score > 1.0000001 or score < -1.0000001
union all
select 'not_descending' as issue
from r a join r b on b.rn = a.rn + 1
where b.score > a.score + 0.0000001
