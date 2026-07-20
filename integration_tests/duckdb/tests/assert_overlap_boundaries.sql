-- Overlap boundaries at target=40, overlap=15, step=25. A unit within the first 15 tokens of
-- its chunk also appears in the previous chunk. Returns rows only on mismatch.
with produced as (
    select chunk_id, array_to_string(list_sort(source_rows), ',') as rows_csv
    from {{ ref('ce_chunk_overlap') }}
),
expected(chunk_id, rows_csv) as (
    values
        ('call_001::1', '1,2'),
        ('call_001::2', '3,4'),
        ('call_001::3', '4,5'),
        ('call_001::4', '5,6'),
        ('call_002::1', '7,8,9'),
        ('call_002::2', '9,10'),
        ('call_002::3', '10')
)
select
    coalesce(p.chunk_id, e.chunk_id) as chunk_id,
    p.rows_csv as produced_rows,
    e.rows_csv as expected_rows
from produced p
full outer join expected e on p.chunk_id = e.chunk_id
where p.rows_csv is distinct from e.rows_csv
