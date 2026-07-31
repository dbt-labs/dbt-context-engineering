{#-
  ce_classify — single-label classification (spec §5.1). Labels come from the output_schema's
  enum (the taxonomy). output_schema is REQUIRED. LIVE-VALIDATION DEFERRED (see ce_generate).

  OUTPUT CONTRACT (normalized 2026-07-29): returns the chosen label as a plain STRING scalar on all
  three engines — NOT the raw per-engine shape. This makes classify output portable and directly
  testable (e.g. ce_conforms_to_schema). The per-engine unwrap lives in each impl:
    - Snowflake  AI_CLASSIFY -> object {"labels": ["x"]}  -> `:labels[0]`   (CONFIRMED 2026-07-29)
    - Databricks ai_classify -> already the bare label string -> identity   (CONFIRMED 2026-07-29)
    - BigQuery   AI.GENERATE(output_schema) -> STRUCT -> `.<enum-field>`     (assumed per docs; confirm live)
-#}

{% macro ce_classify(input_column, prompt=none, output_schema=none, model=none) -%}
    {%- if output_schema is none -%}
        {{ exceptions.raise_compiler_error("ce_classify: output_schema is required (its enum is the label set).") }}
    {%- endif -%}
    {{ return(adapter.dispatch('ce_classify', 'dbt_context_engineering')(
        input_column, prompt, output_schema, model
    )) }}
{%- endmacro %}


{#- The NAME of the first enum-bearing property (the label field) — used to unwrap the BigQuery
    AI.GENERATE STRUCT down to the scalar label. -#}
{% macro ce_schema_label_field(output_schema) -%}
    {%- set sd = fromjson(output_schema) -%}
    {%- set ns = namespace(name=none) -%}
    {%- for pname, pdef in (sd.get('properties', {})).items() -%}
        {%- if ns.name is none and pdef.get('enum') -%}{%- set ns.name = pname -%}{%- endif -%}
    {%- endfor -%}
    {%- if ns.name is none -%}
        {{ exceptions.raise_compiler_error("ce_classify: schema has no enum property to use as the label field.") }}
    {%- endif -%}
    {{- return(ns.name) -}}
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
    {#- AI_CLASSIFY returns {"labels": ["<label>"]}; unwrap to the scalar label (output contract). -#}
    cast((ai_classify(
        {{ dbt_context_engineering.ce_render_prompt(prompt, input_column) }},
        array_construct({% for c in cats %}'{{ c }}'{% if not loop.last %}, {% endif %}{% endfor %})
    )):labels[0] as {{ dbt.type_string() }})
{%- endmacro %}


{% macro databricks__ce_classify(input_column, prompt, output_schema, model) -%}
    {{ dbt_context_engineering.ce_require_databricks_serverless() }}
    {%- set cats = dbt_context_engineering.ce_schema_categories(output_schema) -%}
    {#- ai_classify already returns the chosen label as a STRING — identity (cast for a stable type). -#}
    cast(ai_classify(
        {{ dbt_context_engineering.ce_render_prompt(prompt, input_column) }},
        array({% for c in cats %}'{{ c }}'{% if not loop.last %}, {% endif %}{% endfor %})
    ) as {{ dbt.type_string() }})
{%- endmacro %}


{% macro bigquery__ce_classify(input_column, prompt, output_schema, model) -%}
    {#- BigQuery has no dedicated classify; constrain generation to the enum via output_schema, then
        unwrap the STRUCT down to the enum field so classify returns a scalar label (output contract). -#}
    {%- set _mp = dbt_context_engineering.ce_bq_model_params(var('ce_max_output_tokens', none), var('ce_bq_thinking_budget', none)) -%}
    {%- set _label = dbt_context_engineering.ce_schema_label_field(output_schema) -%}
    cast((AI.GENERATE(
        prompt => {{ dbt_context_engineering.ce_render_prompt(dbt_context_engineering.ce_augment_prompt(prompt, output_schema), input_column) }},
        {% if var('ce_bq_connection', none) %}connection_id => '{{ var("ce_bq_connection") }}',
        {% endif -%}
        endpoint => '{{ model or var("ce_model_classify", "gemini-2.5-flash") }}',
        output_schema => '''{{ dbt_context_engineering.ce_bq_output_schema(output_schema) }}'''
        {%- if _mp != '' %},
        model_params => {{ _mp }}
        {%- endif %}
    )).{{ _label }} as {{ dbt.type_string() }})
{%- endmacro %}
