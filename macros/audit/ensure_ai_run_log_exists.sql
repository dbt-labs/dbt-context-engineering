{#-
  ensure_ai_run_log_exists(): guarantees ai_run_log exists before log_ai_run's INSERT runs against
  it, even the first time it fires on a fresh target via `dbt run --select <one_model>`, which
  never builds ai_run_log itself unless it is selected too.

  Unconditional `create table if not exists`, every call, no existence check first. Safe in both
  cases dbt can put us in:
    - ai_run_log IS selected this invocation: DAG ordering (via the ref() below, which dbt traces
      the same way it traces any other ref() inside a model hook) guarantees dbt finishes building
      the real table before this hook ever fires, so this statement always finds the table already
      there and no-ops.
    - ai_run_log is NOT selected this invocation: nothing else in this invocation creates it, so
      there's no other writer to race.
-#}
{% macro ensure_ai_run_log_exists() -%}
    {%- set log_relation = ref('ai_run_log') -%}
    {%- if execute -%}
        {%- do run_query(
            "create table if not exists " ~ log_relation ~ " as (" ~ dbt_context_engineering.ai_run_log_columns_sql() ~ ")"
        ) -%}
    {%- endif -%}
    {{ return('') }}
{%- endmacro %}
