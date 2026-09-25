-- The governed incremental embed pattern, asserted across a two-build sequence. See TESTING.md.
--
-- Phase 1 (ed_edit_id unset, run with --full-refresh AND --vars '{allow_full_reembed: true}')
-- embeds all 10 rows. The extra var is required because the model pins full_refresh to
-- allow_full_reembed, which is the whole point of require_full_refresh_gate: a bare
-- --full-refresh must not re-embed the corpus.
--
-- Phase 2 (ed_edit_id set to an utterance_id, run WITHOUT either flag) changes exactly that row's
-- text. Exactly one row may be re-embedded, and every other row's embedded_at must stay frozen at
-- its phase-1 value. A re-embed of all 10 is the cost regression this exists to catch; a re-embed
-- of 0 means the content_hash arm of the delta predicate stopped working.
--
-- depends_on: {{ ref('embed_delta') }}

{#- The exact-delta claim is only meaningful when the run is one of the two documented steps.
    embed_delta pins full_refresh to allow_full_reembed, so a plain rebuild of the suite does NOT
    re-embed and legitimately logs 0 rows. Asserting 10 unconditionally would make the standard
    suite fail on its second run, which is the opposite of what this fixture is for. So:

      allow_full_reembed true  -> a forced full re-embed, expect all 10
      ed_edit_id set           -> the phase-2 delta, expect exactly 1
      neither                  -> no row-count claim, only the invariants below

    The invariants hold on every build, so the model is never uncovered. -#}
{% set edit_id = var('ed_edit_id', -1) %}
{% set forced_full = var('allow_full_reembed', false) %}
{% set expected_row_count = 10 if forced_full else (1 if edit_id | int != -1 else none) %}
{% set log_model = "" if "" else var('embedding_model') %}

{% if expected_row_count is not none -%}
select 'wrong_logged_row_count' as issue, cast(row_count as {{ dbt.type_string() }}) as detail
from {{ ref('ai_run_log') }}
where invocation_id = '{{ invocation_id }}'
  and function_name = 'embed'
  and model_name = '{{ log_model }}'
  and event = 'started'
  and row_count <> {{ expected_row_count }}

union all

{% endif -%}
select 'missing_completed_row', null
from (
    select count(*) as n from {{ ref('ai_run_log') }}
    where invocation_id = '{{ invocation_id }}'
      and function_name = 'embed'
      and model_name = '{{ log_model }}'
      and event = 'completed'
) c
where c.n <> 1

union all

-- Every row must carry an embedding, on every phase.
select 'null_embedding', cast(utterance_id as {{ dbt.type_string() }})
from {{ ref('embed_delta') }}
where embedding is null

union all

-- The corpus never grows or shrinks across phases.
select 'wrong_corpus_size', cast(n as {{ dbt.type_string() }})
from (select count(*) as n from {{ ref('embed_delta') }}) t
where n <> 10

union all

-- Phase 2 only: the edited row is the newest, and every other row is frozen at one older
-- timestamp. Two distinct embedded_at values across the table, no more.
select 'edited_row_not_reembedded', null
from {{ ref('embed_delta') }} edited
where {{ edit_id }} != -1
  and edited.utterance_id = {{ edit_id }}
  and edited.embedded_at <= (
      select max(other.embedded_at)
      from {{ ref('embed_delta') }} other
      where other.utterance_id != {{ edit_id }}
  )

union all

select 'untouched_rows_were_reembedded', cast(n as {{ dbt.type_string() }})
from (
    select count(distinct embedded_at) as n
    from {{ ref('embed_delta') }}
    where utterance_id != {{ edit_id }}
) t
where {{ edit_id }} != -1 and n <> 1
