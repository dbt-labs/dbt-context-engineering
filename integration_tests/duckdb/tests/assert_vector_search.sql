-- vector_search must return the top-2 by cosine similarity to [1,0,0]: d1 (identical) then
-- d3 (near), and exactly 2 rows. Returns rows only on failure.
with ranked as (
    select doc_id, score, row_number() over (order by score desc) as rn
    from {{ ref('search_results') }}
)
select 'wrong_rank' as issue, doc_id
from ranked
where (rn = 1 and doc_id <> 'd1')
   or (rn = 2 and doc_id <> 'd3')

union all

select 'wrong_count' as issue, cast(count(*) as varchar)
from {{ ref('search_results') }}
having count(*) <> 2
