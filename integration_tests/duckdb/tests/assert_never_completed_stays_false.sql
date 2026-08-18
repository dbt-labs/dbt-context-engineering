-- logged_never_completed logs (post-hook) but never pairs a complete_ai_run, standing in for a
-- model that errors after log_ai_run fires (dbt skips a model's post-hook when it errors). Its
-- ai_run_log row should stay completed = false forever, across every invocation; any true value
-- here is a bug.
-- depends_on: {{ ref('logged_never_completed') }}
select 'row_should_stay_incomplete' as issue, invocation_id, completed
from {{ ref('ai_run_log') }}
where function_name = 'never_completed'
  and completed = true
