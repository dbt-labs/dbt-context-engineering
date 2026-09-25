-- Overlap boundaries at target=40, overlap=15, step=25. A unit within the first 15 tokens of its
-- chunk also appears in the previous chunk, so chunks share units at their edges. Fail rows only.
--
-- Same two-halves membership check as assert_expected_boundaries, and the same reason for using
-- t_arr_has over a CSV rendering.
with expected as (
    select 'call_001::1' as chunk_id, 1 as utterance_id
    union all select 'call_001::1', 2
    union all select 'call_001::2', 3
    union all select 'call_001::2', 4
    union all select 'call_001::3', 4
    union all select 'call_001::3', 5
    union all select 'call_001::4', 5
    union all select 'call_001::4', 6
    union all select 'call_002::1', 7
    union all select 'call_002::1', 8
    union all select 'call_002::1', 9
    union all select 'call_002::2', 9
    union all select 'call_002::2', 10
    union all select 'call_002::3', 10
),
expected_counts as (
    select chunk_id, count(*) as n_expected from expected group by chunk_id
),
produced as (
    select chunk_id, n_source_rows, source_rows from {{ ref('chunk_overlap') }}
)

select
    coalesce(p.chunk_id, e.chunk_id)                 as chunk_id,
    'unit_count'                                     as issue,
    cast(p.n_source_rows as {{ dbt.type_string() }}) as produced,
    cast(e.n_expected as {{ dbt.type_string() }})    as expected
from produced p
full outer join expected_counts e on p.chunk_id = e.chunk_id
where p.n_source_rows is distinct from e.n_expected

union all

select
    e.chunk_id,
    'missing_unit',
    cast(e.utterance_id as {{ dbt.type_string() }}),
    cast(e.utterance_id as {{ dbt.type_string() }})
from expected e
join produced p on p.chunk_id = e.chunk_id
where not ({{ t_arr_has('p.source_rows', 'e.utterance_id') }})
