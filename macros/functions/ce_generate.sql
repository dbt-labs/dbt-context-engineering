{#-
  ce_generate — free-form generation with optional structured output (spec §5.1).
  Canonical wrapper: the public macro only dispatches; real SQL lives per adapter.

  Args: input_column, prompt (from ce_prompt), output_schema (from ce_schema, optional),
        model (optional; defaults to var ce_model_generate).
  Returns a SQL expression usable inside a select.

  LIVE-VALIDATION DEFERRED: the vendor AI function surface is compile-checked per adapter in CI
  but not executed (no warehouse creds). Argument shapes follow the parity doc / current vendor
  docs and must be re-confirmed against the vendor at live-validation time.
-#}

{% macro ce_generate(input_column, prompt, output_schema=none, model=none) -%}
    {{ return(adapter.dispatch('ce_generate', 'dbt_context_engineering')(
        input_column, prompt, output_schema, model
    )) }}
{%- endmacro %}


{% macro default__ce_generate(input_column, prompt, output_schema, model) -%}
    {{ exceptions.raise_compiler_error(
        "ce_generate is not implemented for the '" ~ target.type ~ "' adapter. "
        ~ "Supported: snowflake, databricks, bigquery.") }}
{%- endmacro %}


{% macro snowflake__ce_generate(input_column, prompt, output_schema, model) -%}
    {%- set model = model or var('ce_model_generate', none) -%}
    {%- if model is none -%}{{ exceptions.raise_compiler_error("ce_generate: set var ce_model_generate or pass model=.") }}{%- endif -%}
    {#- Output cap: AI_COMPLETE takes a model_parameters OBJECT; max_tokens bounds the response.
        No thinking-budget knob here — Cortex models don't run Gemini-style default thinking. -#}
    {%- set _max_out = var('ce_max_output_tokens', none) -%}
    ai_complete(
        model => '{{ model }}',
        prompt => {{ dbt_context_engineering.ce_render_prompt(prompt, input_column) }}
        {%- if _max_out is not none %},
        model_parameters => {'max_tokens': {{ _max_out | int }}}
        {%- endif %}
        {%- if output_schema is not none %},
        {#- response_format is a SQL OBJECT (not a string): {'type':'json','schema': <schema>}.
            The schema is parsed from our JSON literal into an object. -#}
        response_format => {'type': 'json', 'schema': parse_json($${{ output_schema }}$$)}
        {%- endif %}
    )
{%- endmacro %}


{% macro databricks__ce_generate(input_column, prompt, output_schema, model) -%}
    {{ dbt_context_engineering.ce_require_databricks_serverless() }}
    {%- set model = model or var('ce_model_generate', none) -%}
    {%- if model is none -%}{{ exceptions.raise_compiler_error("ce_generate: set var ce_model_generate or pass model=.") }}{%- endif -%}
    {#- Output cap: ai_query takes a modelParameters STRUCT; max_tokens bounds the response.
        No thinking-budget knob — foundation models here don't run thinking on by default. -#}
    {%- set _max_out = var('ce_max_output_tokens', none) -%}
    ai_query(
        '{{ model }}',
        {{ dbt_context_engineering.ce_render_prompt(prompt, input_column) }}
        {%- if _max_out is not none %},
        modelParameters => named_struct('max_tokens', {{ _max_out | int }})
        {%- endif %}
        {%- if output_schema is not none %},
        {#- Databricks needs an OpenAI-style json_schema envelope; a bare JSON-schema object is
            rejected: AI_FUNCTION_UNSUPPORTED_RESPONSE_FORMAT (confirmed live 2026-07-17). The
            package schema rides under json_schema.schema. -#}
        responseFormat => '{"type": "json_schema", "json_schema": {"name": "ce_output", "strict": true, "schema": {{ output_schema }}}}'
        {%- endif %}
    )
{%- endmacro %}


{% macro bigquery__ce_generate(input_column, prompt, output_schema, model) -%}
    {%- set _mp = dbt_context_engineering.ce_bq_model_params(var('ce_max_output_tokens', none), var('ce_bq_thinking_budget', none)) -%}
    {#- BigQuery output_schema can't carry an enum, so inject any enum labels into the prompt
        (ce_augment_prompt) — no-op when the schema has none. -#}
    AI.GENERATE(
        prompt => {{ dbt_context_engineering.ce_render_prompt(dbt_context_engineering.ce_augment_prompt(prompt, output_schema), input_column) }},
        {% if var('ce_bq_connection', none) %}connection_id => '{{ var("ce_bq_connection") }}',
        {% endif -%}
        endpoint => '{{ model or var("ce_model_generate", "gemini-2.5-flash") }}'
        {%- if output_schema is not none %},
        output_schema => '''{{ dbt_context_engineering.ce_bq_output_schema(output_schema) }}'''
        {%- endif %}
        {%- if _mp != '' %},
        model_params => {{ _mp }}
        {%- endif %}
    )
{%- endmacro %}
