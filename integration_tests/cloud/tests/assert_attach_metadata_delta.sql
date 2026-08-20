-- Mirrors the duckdb fixture (tests/assert_attach_metadata_delta.sql): phase 1 (amd_edit_id
-- unset) is the baseline build; phase 2 (amd_edit_id=<a document_id>, run WITHOUT --full-refresh)
-- simulates that document's title changing with its chunk text held constant. Every chunk row
-- belonging to the edited document should show a newer processed_at than every untouched
-- document's chunk rows, and untouched documents' rows should all share one identical (frozen)
-- processed_at. Confirmed live on Snowflake, Databricks, and BigQuery, 2026-08-20.

{% set edit_id = var('amd_edit_id', 'none') %}

select 'null_content_hash_or_processed_at' as issue
from {{ ref('attach_metadata_delta') }}
where content_hash is null or processed_at is null

union all

select 'row_count_mismatch' as issue
from (select count(*) as n from {{ ref('attach_metadata_delta') }}) c
join (select count(*) as n from {{ ref('chunk_docs') }}) d on true
where c.n != d.n

union all

select 'edited_doc_not_reprocessed' as issue
from {{ ref('attach_metadata_delta') }} edited
where '{{ edit_id }}' != 'none'
  and edited.partition_key = '{{ edit_id }}'
  and edited.processed_at <= (
      select min(other.processed_at)
      from {{ ref('attach_metadata_delta') }} other
      where other.partition_key != '{{ edit_id }}'
  )

union all

select 'untouched_docs_not_frozen' as issue
from (
    select min(processed_at) as lo, max(processed_at) as hi
    from {{ ref('attach_metadata_delta') }}
    where '{{ edit_id }}' != 'none' and partition_key != '{{ edit_id }}'
) bounds
where bounds.lo != bounds.hi
