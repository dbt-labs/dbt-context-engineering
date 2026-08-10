-- vector_search must resolve a score tie at the top_k cutoff deterministically via the id_column
-- tiebreaker (finding #10). Query [1,0,0], top_k=2: rank 1 is d1 (identical); ranks 2-4 tie on score,
-- so rank 2 must be 'tie_a' (lowest id among the tied set), not an arbitrary tie_b/tie_c. Returns
-- rows only on failure.
with ranked as (
    select doc_id, score, row_number() over (order by score desc, doc_id) as rn
    from {{ ref('search_ties_results') }}
)
select 'wrong_top' as issue, doc_id
from ranked where rn = 1 and doc_id <> 'd1'

union all
select 'tiebreak_not_applied' as issue, doc_id
from ranked where rn = 2 and doc_id <> 'tie_a'

union all
select 'wrong_count' as issue, cast(count(*) as varchar)
from {{ ref('search_ties_results') }} having count(*) <> 2
