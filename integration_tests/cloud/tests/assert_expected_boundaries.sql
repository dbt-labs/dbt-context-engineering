-- Exact chunk boundaries at target_tokens=40, overlap=0, matching ADR-0002's worked-example shape.
-- Fail rows only.
--
-- Exact membership is asserted as two halves that together imply set equality: each chunk's
-- n_source_rows matches the expected count, and every expected (chunk, unit) pair is present.
-- Membership goes through t_arr_has rather than rendering source_rows to CSV, because these
-- unit ids are integers and the CSV path needs string elements on Databricks and BigQuery.
with expected as (
    select 'call_001::1' as chunk_id, 1 as utterance_id
    union all select 'call_001::1', 2
    union all select 'call_001::2', 3
    union all select 'call_001::2', 4
    union all select 'call_001::2', 5
    union all select 'call_001::3', 6
    union all select 'call_002::1', 7
    union all select 'call_002::1', 8
    union all select 'call_002::1', 9
    union all select 'call_002::2', 10
),
expected_counts as (
    select chunk_id, count(*) as n_expected from expected group by chunk_id
),
produced as (
    select chunk_id, n_source_rows, source_rows from {{ ref('chunk_utterances') }}
)

select
    coalesce(p.chunk_id, e.chunk_id)                        as chunk_id,
    'unit_count'                                            as issue,
    cast(p.n_source_rows as {{ dbt.type_string() }})        as produced,
    cast(e.n_expected as {{ dbt.type_string() }})           as expected
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
