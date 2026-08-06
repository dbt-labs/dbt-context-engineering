{#-
  guard_batch — circuit breaker, used as a pre-hook on any AI model (spec §5.4, D2).
  Pulled forward into Phase 2 so no unguarded AI call ever exists.

  At run time (in a pre-hook) it counts the input relation's rows and estimated tokens
  (estimate_tokens) and RAISES before the model runs if either exceeds max_batch_rows /
  max_est_tokens. Guards the AI call's INPUT relation (which already exists), not the model's
  own output. Ceilings are vars, overridable per run/project.

  Usage:
    {{ config(pre_hook = "{{ guard_batch(ref('my_inputs'), 'text_col') }}") }}
-#}
{% macro guard_batch(relation, input_column=none) -%}
    {#- Only executes against the warehouse at run time; a no-op during parse. -#}
    {%- if not execute -%}{{ return('') }}{%- endif -%}

    {%- set max_rows = var('max_batch_rows', 10000) -%}
    {%- set max_tokens = var('max_est_tokens', 5000000) -%}
    {%- set tok_expr = dbt_context_engineering.estimate_tokens(input_column) if input_column is not none else '0' -%}

    {%- set q -%}
        select
            count(*) as n_rows,
            coalesce(sum({{ tok_expr }}), 0) as est_tokens
        from {{ relation }}
    {%- endset -%}

    {%- set res = run_query(q) -%}
    {%- set n_rows = res.columns[0].values()[0] -%}
    {%- set est_tokens = (res.columns[1].values()[0]) | int -%}

    {%- if n_rows > max_rows or est_tokens > max_tokens -%}
        {{ exceptions.raise_compiler_error(
            "guard_batch: batch exceeds ceiling for " ~ relation ~ " — "
            ~ "rows=" ~ n_rows ~ " (max max_batch_rows=" ~ max_rows ~ "), "
            ~ "est_tokens=" ~ est_tokens ~ " (max max_est_tokens=" ~ max_tokens ~ "). "
            ~ "Raise the ceiling vars or shrink the batch.") }}
    {%- endif -%}
    {{- return('') -}}
{%- endmacro %}
