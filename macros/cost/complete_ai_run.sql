{#-
  complete_ai_run: flips the ai_run_log row log_ai_run inserted for THIS invocation from
  completed = false to true, once the model has finished successfully. A post_hook ONLY — dbt
  never runs a model's post_hook when the model errors, so an incomplete run's row is simply
  never flipped.

  Pass the SAME function_name/model_name given to the paired log_ai_run call on this model, so the
  UPDATE targets exactly the row that call inserted this invocation (matched on invocation_id +
  function_name + model_name + completed = false; that last filter makes a repeated call
  idempotent).

  Usage (pairs with log_ai_run — see its docstring for the pre_hook-vs-post_hook rule when
  `filter` is `this`-derived; complete_ai_run itself has no such hazard, since its UPDATE is keyed
  on invocation_id/function_name/model_name, never on `this`, so it is always safe as a post_hook):
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
    {%- set model_clause = "model_name = '" ~ model_name ~ "'" if model_name is not none else "model_name is null" -%}
    update {{ ref('ai_run_log') }}
    set completed = true
    where invocation_id = '{{ invocation_id }}'
      and function_name = '{{ function_name }}'
      and {{ model_clause }}
      and completed = false
{%- endmacro %}
