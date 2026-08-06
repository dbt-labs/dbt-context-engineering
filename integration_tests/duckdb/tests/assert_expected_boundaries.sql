-- Exact chunk boundaries at target_tokens=40 (matches the Phase 1a worked example).
-- Returns rows only on mismatch.
with produced as (
    select chunk_id, array_to_string(list_sort(source_rows), ',') as rows_csv
    from {{ ref('chunk_utterances') }}
),
expected(chunk_id, rows_csv) as (
    values
        ('call_001::1', '1,2'),
        ('call_001::2', '3,4,5'),
        ('call_001::3', '6'),
        ('call_002::1', '7,8,9'),
        ('call_002::2', '10')
)
select
    coalesce(p.chunk_id, e.chunk_id) as chunk_id,
    p.rows_csv as produced_rows,
    e.rows_csv as expected_rows
from produced p
full outer join expected e on p.chunk_id = e.chunk_id
where p.rows_csv is distinct from e.rows_csv
