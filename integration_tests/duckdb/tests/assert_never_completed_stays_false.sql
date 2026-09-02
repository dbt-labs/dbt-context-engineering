-- logged_never_completed logs (post-hook) but never pairs a complete_ai_run, standing in for a
-- model that errors after log_ai_run fires (dbt skips a model's post-hook when it errors). No
-- 'completed' row should ever appear for it, across every invocation; any 'completed' row here is
-- a bug.
-- depends_on: {{ ref('logged_never_completed') }}
select 'completed_row_should_never_exist' as issue, invocation_id, event
from {{ ref('ai_run_log') }}
where function_name = 'never_completed'
  and event = 'completed'
