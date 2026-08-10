-- logged_delta's log_ai_run runs as a pre-hook so it reads the same pre-merge state the model
-- body's delta filter reads, so its row_count should equal exactly the rows that run processed.
-- Asserts row_count=5 on both phase 1 (the 5-row baseline) and phase 2 (the real incremental
-- delta, utterance_id 6-10). See TESTING.md §4.2 for the two build commands this runs under.
-- log_ai_run's insert is a hook side effect invisible to the DAG (this test only refs ai_run_log,
-- not logged_delta directly), so ordering has to be forced explicitly here, or this test could run
-- before the model and pass vacuously on zero rows for this invocation_id:
-- depends_on: {{ ref('logged_delta') }}
select 'wrong_row_count' as issue, row_count
from {{ ref('ai_run_log') }}
where invocation_id = '{{ invocation_id }}'
  and function_name = 'embed'
  and model_name = 'logged-delta-test'
  and row_count <> 5
