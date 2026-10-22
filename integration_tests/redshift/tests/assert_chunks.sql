-- LIVE validation of chunk on Redshift, specifically that array_agg built a SUPER array whose
-- element count matches n_source_rows (i.e. json_parse('['||listagg(...)||']') produced a real,
-- correctly-sized array), and chunk_text/n_source_rows are well-formed. Fail rows only.
select 'source_rows_count_mismatch' as issue, chunk_id
from {{ ref('rs_chunks') }}
where get_array_length(source_rows) <> n_source_rows
union all
select 'empty_or_null_chunk' as issue, chunk_id
from {{ ref('rs_chunks') }}
where n_source_rows < 1 or chunk_text is null
