{#-
  extract — typed extraction into the fields defined by output_schema (spec §5.1).
  Same signature as generate; output_schema is REQUIRED (it is the extraction contract, and
  should include an evidence/quote field for lineage). LIVE-VALIDATION DEFERRED (see generate).
-#}

{% macro extract(input_column, prompt=none, output_schema=none, model=none) -%}
    {{ dbt_context_engineering.require_ai_functions_enabled('extract') }}
    {{ dbt_context_engineering.require_safe_materialization('extract') }}
    {%- if output_schema is none -%}
        {{ exceptions.raise_compiler_error("extract: output_schema is required (it is the extraction contract).") }}
    {%- endif -%}
    {{ return(adapter.dispatch('extract', 'dbt_context_engineering')(
        input_column, prompt, output_schema, model
    )) }}
{%- endmacro %}


{% macro default__extract(input_column, prompt, output_schema, model) -%}
    {{ exceptions.raise_compiler_error(
        "extract is not implemented for the '" ~ target.type ~ "' adapter. "
        ~ "Supported: snowflake, databricks, bigquery.") }}
{%- endmacro %}


{% macro snowflake__extract(input_column, prompt, output_schema, model) -%}
    {#- Converged onto AI_COMPLETE + response_format (issue #3, ADR-0018). AI_EXTRACT cannot enforce a
        schema `enum` (its responseFormat supports only a string scalar) and returns the string "None"
        for a field it cannot fill, so it produced off-taxonomy and "None" signals. AI_COMPLETE binds
        the `enum` structurally (proven live) and returns the fields object directly, no `:response`
        envelope, so field reads it the same as generate's output. This matches how Databricks
        (ai_query) and BigQuery (AI.GENERATE) already implement extract: extract is the engine's
        structured-generate primitive. `evidence` is optional in the schema, so a genuinely quote-less
        row yields null rather than a fabricated citation (AI_COMPLETE invents a value for a required
        field it cannot fill; confirmed live 2026-07-31). -#}
    {%- set model = model or var('model_extract', var('model_generate', none)) -%}
    {%- if model is none -%}{{ exceptions.raise_compiler_error("extract: set var model_extract or model_generate (Snowflake routes extract through ai_complete).") }}{%- endif -%}
    {%- set _max_out = var('max_output_tokens', none) -%}
    ai_complete(
        model => '{{ model }}',
        prompt => {{ dbt_context_engineering.render_prompt(prompt, input_column) }}
        {%- if _max_out is not none %},
        model_parameters => {'max_tokens': {{ _max_out | int }}}
        {%- endif %},
        response_format => {'type': 'json', 'schema': parse_json($${{ output_schema }}$$)}
    )
{%- endmacro %}


{% macro databricks__extract(input_column, prompt, output_schema, model) -%}
    {{ dbt_context_engineering.require_databricks_serverless() }}
    {#- Databricks `ai_extract` is label-based (an array of field names) and cannot honor the
        package's typed schema — enums, the evidence/quote field, additionalProperties. It rejects
        a JSON schema outright (AI_FUNCTION_COMPILATION_ERROR). Route extraction through `ai_query`
        structured output — the same json_schema envelope generate uses — so the output_schema
        contract holds. Confirmed live 2026-07-17. -#}
    {%- set model = model or var('model_extract', var('model_generate', none)) -%}
    {%- if model is none -%}{{ exceptions.raise_compiler_error("extract: set var model_extract or model_generate (Databricks routes extract through ai_query).") }}{%- endif -%}
    {%- set _max_out = var('max_output_tokens', none) -%}
    ai_query(
        '{{ model }}',
        {{ dbt_context_engineering.render_prompt(prompt, input_column) }}
        {%- if _max_out is not none %},
        modelParameters => named_struct('max_tokens', {{ _max_out | int }})
        {%- endif %},
        responseFormat => '{"type": "json_schema", "json_schema": {"name": "output", "strict": true, "schema": {{ output_schema }}}}'
    )
{%- endmacro %}


{% macro bigquery__extract(input_column, prompt, output_schema, model) -%}
    {#- AI.GENERATE_TABLE is a TABLE function (can't sit in a SELECT column). For a row-level
        scalar extract we use AI.GENERATE with output_schema, which returns a typed STRUCT per row. -#}
    {%- set _mp = dbt_context_engineering.bq_model_params(var('max_output_tokens', none), var('bq_thinking_budget', none)) -%}
    {#- Inject enum labels into the prompt — BigQuery output_schema can't carry them (see augment_prompt). -#}
    AI.GENERATE(
        prompt => {{ dbt_context_engineering.render_prompt(dbt_context_engineering.augment_prompt(prompt, output_schema), input_column) }},
        {% if var('bq_connection', none) %}connection_id => '{{ var("bq_connection") }}',
        {% endif -%}
        endpoint => '{{ model or var("model_extract", "gemini-2.5-flash") }}',
        output_schema => '''{{ dbt_context_engineering.bq_output_schema(output_schema) }}'''
        {%- if _mp != '' %},
        model_params => {{ _mp }}
        {%- endif %}
    )
{%- endmacro %}
