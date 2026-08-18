-- content_hash_delta's log_ai_run runs as a pre-hook so it reads the same pre-merge state the
-- model body's delta filter reads. Phase 1 (ch_edit_id unset, the default) is the full 10-row
-- baseline. Phase 2 (ch_edit_id=<some utterance_id>, run WITHOUT --full-refresh right after phase
-- 1) simulates that one row's source text changing; row_count should be exactly 1, the row whose
-- content_hash actually changed, not the whole 10-row corpus and not 0. See ADR-0023.
--
-- depends_on: {{ ref('content_hash_delta') }}

{% set edit_id = var('ch_edit_id', -1) %}
{% set expected_row_count = 1 if edit_id | int != -1 else 10 %}

select 'wrong_row_count' as issue, row_count
from {{ ref('ai_run_log') }}
where invocation_id = '{{ invocation_id }}'
  and function_name = 'embed'
  and model_name = 'content-hash-delta-test'
  and (row_count <> {{ expected_row_count }} or completed <> true)

union all

select 'edited_row_not_reembedded' as issue, null as row_count
from {{ ref('content_hash_delta') }} edited
where {{ edit_id }} != -1
  and edited.utterance_id = {{ edit_id }}
  and edited.embedded_at <= (
      select min(other.embedded_at)
      from {{ ref('content_hash_delta') }} other
      where other.utterance_id != {{ edit_id }}
  )
