{#-
  ai_run_log — append-only usage/cost log (spec §5.4, Phase 3).

  Incremental table whose own SELECT defines the schema but emits NO rows (where 1=0); the column
  list/types live in ai_run_log_columns_sql() so ensure_ai_run_log_exists() can create the same
  shape directly, without dbt-building this model first. Rows are appended by log_ai_run
  (pre_hook or post_hook — see its docstring for which) at completed = false, flipped to true by
  complete_ai_run's post_hook once the model finishes; if the model errors mid-run, dbt never
  runs that post_hook, so the row stays false. The log persists and grows across dbt invocations
  (a full-refresh resets it).
-#}
{{ config(materialized='incremental') }}

{{ dbt_context_engineering.ai_run_log_columns_sql() }}
