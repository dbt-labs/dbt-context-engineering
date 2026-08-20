-- Phase 1 (amd_edit_id unset, the default): baseline build, every chunk_docs row passed through
-- attach_metadata_delta untouched. Phase 2 (amd_edit_id=<a document_id>, run WITHOUT
-- --full-refresh right after phase 1): simulates that document's title changing with its chunk
-- text held constant. Expect every chunk row belonging to that document (chunk_docs partitions on
-- document_id, so a document can produce more than one chunk) to show a newer processed_at than
-- every chunk row belonging to an untouched document, proving the metadata-only edit was caught
-- and reprocessed rather than frozen. See ADR-0023 (the same content-hash-delta mechanism, applied
-- here to attach_metadata instead of embed) and docs/DEFERRED.md #2.

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

-- every untouched document's chunk rows must share one identical (frozen) processed_at; any
-- variance means phase 2 reprocessed a row it should have left alone.
select 'untouched_docs_not_frozen' as issue
from (
    select min(processed_at) as lo, max(processed_at) as hi
    from {{ ref('attach_metadata_delta') }}
    where '{{ edit_id }}' != 'none' and partition_key != '{{ edit_id }}'
) bounds
where bounds.lo != bounds.hi
