{#-
  ai_agg: group-level LLM aggregation, a GROUP BY-compatible companion to generate/classify/extract
  (ADR-0028). Returns a single SQL aggregate expression for the caller's own GROUP BY; like the
  other three operations, this macro never owns row grain, the caller's GROUP BY does.

  Snowflake's AI_AGG and BigQuery's AI.AGG are native aggregates. Databricks has no equivalent, so
  its path is a composition, collapse the group with a standard SQL aggregate, then generate from
  the result via ai_query, bounded by a caller-applied per-group size guard (guard_agg_batch in
  macros/cost/guard_batch.sql), not an attempt at map-reduce (ADR-0028).

  CROSS-ADAPTER CAVEATS (live-validated 2026-08-23, ADR-0028), read before relying on either:
    - model: honored on Databricks (passed to ai_query) and on BigQuery (passed to AI.AGG's
      endpoint argument). NO-OP on Snowflake, AI_AGG exposes no model/endpoint argument at all, the
      engine picks internally.
    - order_column: honored on Databricks, used to deterministically sort the group before
      collapsing it (collect_list/array_agg do not support an inline ORDER BY on this engine).
      NO-OP on BigQuery, confirmed order-insensitive across three live trials. On Snowflake, AI_AGG
      DOES respect input row order, but only if the CALLER pre-sorts their own FROM clause, this
      macro returns one expression and cannot alter the caller's FROM clause, so order_column is
      accepted here for signature consistency but does not by itself control order on Snowflake.
    - Databricks has no internal map-reduce for an oversized group, unlike Snowflake/BigQuery. A
      Databricks ai_agg call should be paired with guard_agg_batch in a pre_hook.

  Args: input_column, prompt (a plain instruction string, no {{ input }} placeholder, this is an
        aggregate instruction, not a per-row template), order_column (optional, Databricks-only,
        see above), model (optional, Databricks/BigQuery only, see above; defaults to
        var('model_agg', var('model_generate', ...))).
-#}
{% macro ai_agg(input_column, prompt, order_column=none, model=none) -%}
    {{ dbt_context_engineering.require_ai_functions_enabled('ai_agg') }}
    {{ dbt_context_engineering.require_safe_materialization('ai_agg') }}
    {{ dbt_context_engineering.require_full_refresh_gate('ai_agg') }}
    {{ return(adapter.dispatch('ai_agg', 'dbt_context_engineering')(
        input_column, prompt, order_column, model
    )) }}
{%- endmacro %}


{% macro default__ai_agg(input_column, prompt, order_column, model) -%}
    {#- execute-gated, same reasoning as default__embed: this return value is spliced into the
        caller's own SELECT, so parse time needs a valid placeholder, not an empty string. -#}
    {%- if execute -%}
        {{ exceptions.raise_compiler_error(
            "ai_agg is not implemented for the '" ~ target.type ~ "' adapter. "
            ~ "Supported: snowflake, databricks, bigquery.") }}
    {%- endif -%}
    {{ return('null') }}
{%- endmacro %}


{% macro snowflake__ai_agg(input_column, prompt, order_column, model) -%}
    {#- order_column and model are accepted for signature consistency but are no-ops here: AI_AGG
        takes no model argument (Cortex picks internally), and honoring row order requires the
        CALLER's own FROM clause to be pre-sorted, which this macro (a single expression) cannot
        do (confirmed live 2026-08-23, ADR-0028). -#}
    ai_agg({{ input_column }}, {{ dbt_context_engineering.str_literal(prompt) }})
{%- endmacro %}


{% macro databricks__ai_agg(input_column, prompt, order_column, model) -%}
    {{ dbt_context_engineering.require_databricks_serverless() }}
    {%- set model = model or var('model_agg', var('model_generate', none)) -%}
    {#- execute-gated, same reasoning as default__ai_agg above: an unguarded raise here breaks
        parsing of the whole project the moment any model anywhere calls ai_agg() without a
        model var set, not just the model that does. -#}
    {%- if model is none -%}{%- if execute -%}{{ exceptions.raise_compiler_error("ai_agg: set var model_agg or model_generate (Databricks routes ai_agg through ai_query).") }}{%- else -%}{%- set model = 'unset' -%}{%- endif -%}{%- endif -%}
    {#- collect_list/array_agg do not support an inline ORDER BY on this engine (confirmed live
        2026-08-23: neither `array_agg(x order by y)` nor `... within group (order by y)` compiles),
        so a deterministic order needs sort_array over a struct instead. Without order_column, the
        group is collapsed in whatever order collect_list happens to return, which is unspecified. -#}
    {%- if order_column is not none -%}
        {%- set collapsed = 'array_join(transform(sort_array(collect_list(struct(' ~ order_column ~ ', ' ~ input_column ~ '))), x -> x.' ~ input_column ~ '), chr(10))' -%}
    {%- else -%}
        {%- set collapsed = 'array_join(collect_list(' ~ input_column ~ '), chr(10))' -%}
    {%- endif -%}
    ai_query('{{ model }}', {{ dbt_context_engineering.str_literal(prompt) }} || chr(10) || chr(10) || {{ collapsed }})
{%- endmacro %}


{% macro bigquery__ai_agg(input_column, prompt, order_column, model) -%}
    {#- order_column is accepted for signature consistency but is a no-op here: confirmed
        order-insensitive across three live trials 2026-08-23 (ADR-0028), pre-sorting the caller's
        FROM clause had no effect. model IS honored, unlike Snowflake, AI.AGG's endpoint argument
        maps to the same var('model_generate', ...) generate()/classify()/extract() already use. -#}
    AI.AGG(
        {{ input_column }},
        {{ dbt_context_engineering.str_literal(prompt) }},
        endpoint => '{{ model or var("model_agg", var("model_generate", "gemini-2.5-flash")) }}'
        {%- if var('bq_connection', none) %},
        connection_id => '{{ var("bq_connection") }}'
        {%- endif %}
    )
{%- endmacro %}
