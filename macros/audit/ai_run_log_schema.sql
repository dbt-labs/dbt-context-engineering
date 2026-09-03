{#-
  ai_run_log_columns_sql(): the single source of truth for ai_run_log's column list and types.
  Shared by the model's own defining SELECT (models/audit/ai_run_log.sql) and by
  create_ai_run_log_table(), which creates the same empty, typed table directly for a consumer's
  own on-run-start hook, before the model has ever been dbt-built in that target. Emits NO rows
  (where 1=0), it exists purely to fix column names/types in one place.
-#}
{% macro ai_run_log_columns_sql() -%}
select
    cast(null as {{ dbt.type_string() }})    as invocation_id,
    cast(null as {{ dbt.type_string() }})    as model_name,
    cast(null as {{ dbt.type_string() }})    as function_name,
    cast(null as {{ dbt.type_int() }})       as row_count,
    cast(null as {{ dbt.type_numeric() }})   as est_tokens,
    cast(null as {{ dbt.type_numeric() }})   as est_cost,
    cast(null as {{ dbt.type_timestamp() }}) as run_at,
    cast(null as {{ dbt.type_string() }})    as event
-- from (select 1) gives the WHERE a FROM (BigQuery forbids WHERE without FROM); 0 rows, typed columns
from (select 1) as _one
where 1 = 0
{%- endmacro %}
