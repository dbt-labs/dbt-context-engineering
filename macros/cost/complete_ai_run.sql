{#-
  complete_ai_run: appends a second ai_run_log row for THIS invocation, at event = 'completed',
  once the model has finished successfully. A post_hook ONLY — dbt never runs a model's post_hook
  when the model errors, so an incomplete run simply never gets a 'completed' row. Completion is
  read as an existence check (a 'completed' row matching invocation_id/function_name/model_name),
  not as a mutated field on the 'started' row log_ai_run inserted.

  A pure INSERT, not an UPDATE. Two or more AI-calling models, selected in the same invocation with
  no dependency between them, run on different threads and pair log_ai_run/complete_ai_run
  independently. Two concurrent appends to the same table are not writes to the same row, so
  nothing here conflicts the way a concurrent UPDATE against a shared table would. See ADR-0031
  for the live evidence.

  Pass the SAME function_name/model_name given to the paired log_ai_run call on this model, so a
  downstream reconciliation can join this row back to the 'started' row it completes, on
  invocation_id + function_name + model_name.

  Usage (pairs with log_ai_run — see its docstring for the pre_hook-vs-post_hook rule when
  `filter` is `this`-derived; complete_ai_run itself has no such hazard, since it never
  references `this`, so it is always safe as a post_hook):
    {{ config(
         post_hook = [
           "{{ log_ai_run('classify', model_name='claude-3-5-sonnet') }}",
           "{{ complete_ai_run('classify', model_name='claude-3-5-sonnet') }}"
         ]
       ) }}

  Args:
    function_name  same value passed to the paired log_ai_run call. Required.
    model_name     same value passed to the paired log_ai_run call. Optional.
-#}
{% macro complete_ai_run(function_name, model_name=none) -%}
    {#- No execute-guard: the ref() below must always render for dbt to infer the ai_run_log
        dependency, same as log_ai_run. -#}
    {%- set model_sql = "'" ~ model_name ~ "'" if model_name is not none else "cast(null as " ~ dbt.type_string() ~ ")" -%}
    insert into {{ ref('ai_run_log') }}
        (invocation_id, model_name, function_name, row_count, est_tokens, est_cost, run_at, event)
    select
        '{{ invocation_id }}',
        {{ model_sql }},
        '{{ function_name }}',
        cast(null as {{ dbt.type_int() }}),
        cast(null as {{ dbt.type_numeric() }}),
        cast(null as {{ dbt.type_numeric() }}),
        cast({{ dbt.current_timestamp() }} as {{ dbt.type_timestamp() }}),
        'completed'
{%- endmacro %}
