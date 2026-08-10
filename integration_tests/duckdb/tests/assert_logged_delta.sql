-- logged_delta's log_ai_run (pre-hook, scoped by incremental_delta_predicate) must record the
-- REAL per-run delta, not the full corpus and not zero. Run once per phase (see TESTING.md §4.x);
-- both phase 1 (5-row baseline) and phase 2 (utterance_id 6-10, the real delta) expect row_count=5.
-- A regression to post-hook placement would show row_count=0 on the phase-2 run.
-- The post-hook side effect is invisible to the DAG (this test only refs ai_run_log, not
-- logged_delta directly), so force ordering, or this can run before the model and pass vacuously
-- on zero rows for this invocation_id:
-- depends_on: {{ ref('logged_delta') }}
select 'wrong_row_count' as issue, row_count
from {{ ref('ai_run_log') }}
where invocation_id = '{{ invocation_id }}'
  and function_name = 'embed'
  and model_name = 'logged-delta-test'
  and row_count <> 5
