-- vector_search with a score tie straddling the top_k cutoff. Query [1,0,0], top_k=2: rank 1 is
-- d1 (identical), and ranks 2 to 4 tie on score, so the cutoff falls inside the tied set.
-- Fail rows only.
--
-- The guarantee differs by engine, so the assertion does too.
--
-- On duckdb, Snowflake and Databricks, vector_search emits ORDER BY score desc, id_column and
-- the engine applies it before LIMIT, so the tiebreaker decides which tied row crosses the
-- cutoff. The boundary row must be 'tie_a', the lowest id among the tied set, on every run.
--
-- On BigQuery it does not. vector_search there calls the VECTOR_SEARCH table function, which
-- selects top_k rows itself, and the ORDER BY only sorts what it returned. Which tied row
-- crosses the cutoff is decided inside the function and is NOT stable: measured across repeated
-- runs on identical data, the boundary row varies. What does hold is that the boundary row comes
-- from the tied set, so scoring is still correct and only the choice among equals is arbitrary.
-- That is what is asserted here, and it still catches a real ranking regression, such as an
-- orthogonal row crossing the cutoff. See assert_vector_search_tie_ordering for the ordering
-- guarantee BigQuery does keep, and README's vector_search entry for the consumer-facing note.
with ranked as (
    select doc_id, score, row_number() over (order by score desc, doc_id) as rn
    from {{ ref('search_ties_results') }}
)
select 'wrong_top' as issue, doc_id
from ranked where rn = 1 and doc_id <> 'd1'

union all

{% if target.type == 'bigquery' -%}
select 'boundary_row_outside_tied_set', doc_id
from ranked where rn = 2 and doc_id not in ('tie_a', 'tie_b', 'tie_c')
{%- else -%}
select 'tiebreak_not_applied', doc_id
from ranked where rn = 2 and doc_id <> 'tie_a'
{%- endif %}

union all

select 'wrong_count', cast(count(*) as {{ dbt.type_string() }})
from {{ ref('search_ties_results') }} having count(*) <> 2
