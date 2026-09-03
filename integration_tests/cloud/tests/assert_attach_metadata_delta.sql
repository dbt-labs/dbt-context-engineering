-- attach_metadata's macro-owned incremental mechanism: content_hash computed internally from
-- chunk_text plus metadata_columns, merge on chunk_id, no caller-assembled hash. Returns rows
-- only on violation.
--
-- Ordered two-phase test, same contract as assert_content_hash_delta and assert_chunk_delta:
--   phase 1   dbt build --full-refresh
--             --select attach_metadata_delta_meta_stg attach_metadata_delta   (amd_edit_id unset)
--   phase 2   dbt build --select attach_metadata_delta_meta_stg attach_metadata_delta
--             --vars '{amd_edit_id: doc_2}'   (NO --full-refresh, directly after phase 1)
--
-- Phase 2 edits doc_2's title only. chunk_docs' own chunk_text for doc_2 is untouched, so this
-- is the case attach_metadata has to catch on its own: chunk_text unchanged, metadata changed,
-- the exact gap a plain key-existence check cannot see.
--
-- depends_on: {{ ref('attach_metadata_delta') }}

{% set edit_id = var('amd_edit_id', 'none') %}

{% if edit_id != 'none' %}

-- The edited document's chunk must show a newer built_at than every untouched chunk, proving
-- the delta actually reprocessed it rather than freezing it like the rest.
select 'edited_chunk_not_rebuilt' as issue,
       cast(edited.built_at as {{ dbt.type_string() }}) as detail
from {{ ref('attach_metadata_delta') }} edited
where edited.partition_key = '{{ edit_id }}'
  and edited.built_at <= (
      select min(other.built_at)
      from {{ ref('attach_metadata_delta') }} other
      where other.partition_key <> '{{ edit_id }}'
  )

union all

-- Every other document's chunks were skipped, keeping phase 1's built_at. Row-level, not
-- aggregated: a bare aggregate with no HAVING returns one row even over empty input, which
-- would make this branch fire unconditionally.
select 'untouched_chunk_was_rewritten', cast(c.built_at as {{ dbt.type_string() }})
from {{ ref('attach_metadata_delta') }} c
where c.partition_key <> '{{ edit_id }}'
  and c.built_at >= (
      select min(e.built_at)
      from {{ ref('attach_metadata_delta') }} e
      where e.partition_key = '{{ edit_id }}'
  )

union all

select 'unexpected_total_rows', cast(count(*) as {{ dbt.type_string() }})
from {{ ref('attach_metadata_delta') }}
having count(*) <> 4

{% else %}

select 'baseline_total_rows' as issue, cast(count(*) as {{ dbt.type_string() }}) as detail
from {{ ref('attach_metadata_delta') }}
having count(*) <> 4

union all

select 'baseline_content_hash_missing', cast(count(*) as {{ dbt.type_string() }})
from {{ ref('attach_metadata_delta') }}
where content_hash is null
having count(*) <> 0

{% endif %}
