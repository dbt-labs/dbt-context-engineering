{#-
  ai_run_log — append-only usage/cost log (spec §5.4, Phase 3).

  Incremental table whose own SELECT defines the schema but emits NO rows (where 1=0); the column
  list/types live in ai_run_log_columns_sql() so create_ai_run_log_table() can create the same
  shape directly, without dbt-building this model first (see that macro's docstring for why a
  consumer would want to, via their own on-run-start hook). Event-sourced, append-only: log_ai_run
  (pre_hook or post_hook — see its docstring for which) inserts one row at event = 'started';
  complete_ai_run's post_hook, once the model finishes, appends a SECOND row for the same
  invocation at event = 'completed'. If the model errors mid-run, dbt never runs that post_hook,
  so no 'completed' row ever appears for it. Nothing is ever mutated in place; completion is read
  by checking whether a matching 'completed' row exists, joined to its 'started' row on
  invocation_id + function_name + model_name. The log persists and grows across dbt invocations
  (a full-refresh resets it).
-#}
{{ config(materialized='incremental') }}

{{ dbt_context_engineering.ai_run_log_columns_sql() }}
