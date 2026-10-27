-- knowledge_base's macro-owned per-arm incremental mechanism: source_key synthesized from
-- source_type + source_id, content_hash computed internally per source arm, merge on
-- source_key, no caller-assembled formula. Returns rows only on violation.
--
-- Ordered two-phase test, same contract as assert_chunk_delta and assert_attach_metadata_delta:
--   phase 1   dbt build --full-refresh
--             --select kb_delta_tickets_stg kb_delta_calls_stg kb_delta   (kbd_phase unset)
--   phase 2   dbt build --select kb_delta_tickets_stg kb_delta_calls_stg kb_delta
--             --vars '{kbd_phase: 2}'   (NO --full-refresh, directly after phase 1)
--
-- Phase 2 edits t2's text, adds a brand-new t3, and leaves t1 AND the entire calls arm (c1)
-- untouched. The calls arm is the point of this fixture: an outer wrap-and-filter would get
-- correctness here but still fully scan, cast, and union the calls source every run; filtering
-- inside each arm means an untouched source contributes nothing past its own delta check.
--
-- depends_on: {{ ref('kb_delta') }}

{% set phase = var('kbd_phase', 1) | int %}

{% if phase == 2 %}

-- t2 was edited: must show a newer built_at than every untouched row.
select 'edited_row_not_rebuilt' as issue,
       cast(edited.built_at as {{ dbt.type_string() }}) as detail
from {{ ref('kb_delta') }} edited
where edited.source_key = 'ticket::t2'
  and edited.built_at <= (
      select min(other.built_at)
      from {{ ref('kb_delta') }} other
      where other.source_key <> 'ticket::t2'
  )

union all

-- t3 is new and must be present.
select 'new_row_missing', cast(count(*) as {{ dbt.type_string() }})
from {{ ref('kb_delta') }}
where source_key = 'ticket::t3'
having count(*) <> 1

union all

-- t1 and the WHOLE calls arm (c1) were never touched. Row-level, not aggregated: a bare
-- aggregate with no HAVING returns one row even over empty input, which would make this branch
-- fire unconditionally.
select 'untouched_row_was_rewritten', cast(c.built_at as {{ dbt.type_string() }})
from {{ ref('kb_delta') }} c
where c.source_key in ('ticket::t1', 'call::c1')
  and c.built_at >= (
      select min(e.built_at) from {{ ref('kb_delta') }} e where e.source_key = 'ticket::t2'
  )

union all

select 'unexpected_total_rows', cast(count(*) as {{ dbt.type_string() }})
from {{ ref('kb_delta') }}
having count(*) <> 4

{% else %}

select 'baseline_total_rows' as issue, cast(count(*) as {{ dbt.type_string() }}) as detail
from {{ ref('kb_delta') }}
having count(*) <> 3

union all

select 'baseline_content_hash_missing', cast(count(*) as {{ dbt.type_string() }})
from {{ ref('kb_delta') }}
where content_hash is null or source_key is null
having count(*) <> 0

{% endif %}
