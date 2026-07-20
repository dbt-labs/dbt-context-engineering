{#-
  ce_classify — single-label classification (spec §5.1). Labels come from the output_schema's
  enum (the taxonomy). output_schema is REQUIRED. LIVE-VALIDATION DEFERRED (see ce_generate).
-#}

{% macro ce_classify(input_column, prompt=none, output_schema=none, model=none) -%}
    {%- if output_schema is none -%}
        {{ exceptions.raise_compiler_error("ce_classify: output_schema is required (its enum is the label set).") }}
    {%- endif -%}
    {{ return(adapter.dispatch('ce_classify', 'dbt_context_engineering')(
        input_column, prompt, output_schema, model
    )) }}
{%- endmacro %}


{#- Pull the label set from the first enum-bearing property of the schema. -#}
{% macro ce_schema_categories(output_schema) -%}
    {%- set sd = fromjson(output_schema) -%}
    {%- set ns = namespace(cats=[]) -%}
    {%- for pname, pdef in (sd.get('properties', {})).items() -%}
        {%- if (ns.cats | length) == 0 and pdef.get('enum') -%}
            {%- set ns.cats = pdef.get('enum') -%}
        {%- endif -%}
    {%- endfor -%}
    {%- if (ns.cats | length) == 0 -%}
        {{ exceptions.raise_compiler_error("ce_classify: schema has no enum property to use as the label set.") }}
    {%- endif -%}
    {{- return(ns.cats) -}}
{%- endmacro %}


{% macro default__ce_classify(input_column, prompt, output_schema, model) -%}
    {{ exceptions.raise_compiler_error(
        "ce_classify is not implemented for the '" ~ target.type ~ "' adapter. "
        ~ "Supported: snowflake, databricks, bigquery.") }}
{%- endmacro %}


{% macro snowflake__ce_classify(input_column, prompt, output_schema, model) -%}
    {%- set cats = dbt_context_engineering.ce_schema_categories(output_schema) -%}
    ai_classify(
        {{ dbt_context_engineering.ce_render_prompt(prompt, input_column) }},
        array_construct({% for c in cats %}'{{ c }}'{% if not loop.last %}, {% endif %}{% endfor %})
    )
{%- endmacro %}


{% macro databricks__ce_classify(input_column, prompt, output_schema, model) -%}
    {{ dbt_context_engineering.ce_require_databricks_serverless() }}
    {%- set cats = dbt_context_engineering.ce_schema_categories(output_schema) -%}
    ai_classify(
        {{ dbt_context_engineering.ce_render_prompt(prompt, input_column) }},
        array({% for c in cats %}'{{ c }}'{% if not loop.last %}, {% endif %}{% endfor %})
    )
{%- endmacro %}


{% macro bigquery__ce_classify(input_column, prompt, output_schema, model) -%}
    {#- BigQuery has no dedicated classify; constrain generation to the enum via output_schema. -#}
    {%- set _mp = dbt_context_engineering.ce_bq_model_params(var('ce_max_output_tokens', none), var('ce_bq_thinking_budget', none)) -%}
    AI.GENERATE(
        prompt => {{ dbt_context_engineering.ce_render_prompt(prompt, input_column) }},
        {% if var('ce_bq_connection', none) %}connection_id => '{{ var("ce_bq_connection") }}',
        {% endif -%}
        endpoint => '{{ model or var("ce_model_classify", "gemini-2.5-flash") }}',
        output_schema => '''{{ dbt_context_engineering.ce_bq_output_schema(output_schema) }}'''
        {%- if _mp != '' %},
        model_params => {{ _mp }}
        {%- endif %}
    )
{%- endmacro %}
