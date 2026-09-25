-- With top_k=4 no cutoff falls inside the three-way tie, so vector_search's
-- ORDER BY score desc, id_column governs the entire result and the ordering is fully determined:
-- d1 (identical, score 1.0), then tie_a, tie_b, tie_c by id. Fail rows only.
--
-- Holds on all four engines, BigQuery included. This is the half of the tiebreaker guarantee
-- BigQuery does keep: its VECTOR_SEARCH table function chooses which rows come back, and the
-- ORDER BY then sorts them. When every row comes back there is nothing left for the table
-- function to decide. assert_vector_search_tiebreak covers the half where it does decide.
with ranked as (
    select doc_id, row_number() over (order by score desc, doc_id) as rn
    from {{ ref('search_ties_full') }}
),
expected as (
    select 1 as rn, 'd1' as doc_id
    union all select 2, 'tie_a'
    union all select 3, 'tie_b'
    union all select 4, 'tie_c'
)
select
    coalesce(r.rn, e.rn) as rn,
    r.doc_id             as produced,
    e.doc_id             as expected
from ranked r
full outer join expected e on r.rn = e.rn
where r.doc_id is distinct from e.doc_id
