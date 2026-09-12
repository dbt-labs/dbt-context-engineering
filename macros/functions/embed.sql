{#-
  embed — row-level embedding of a text column (spec §5.1). No prompt/schema; the embedding
  model is pinned via var embedding_model (a corpus embedded by one model cannot be searched
  by another — see Phase 5). LIVE-VALIDATION DEFERRED.

  Scalar on all three engines: Snowflake AI_EMBED, Databricks ai_query (serving endpoint), and
  BigQuery AI.EMBED (the newer AI.* GA family — endpoint + connection_id inline, no CREATE MODEL).
  The older BigQuery ML.GENERATE_EMBEDDING is a TABLE function and is intentionally not used here.
-#}

{% macro embed(input_column, model=none) -%}
    {{ dbt_context_engineering.require_ai_functions_enabled('embed') }}
    {{ dbt_context_engineering.require_safe_materialization('embed') }}
    {{ dbt_context_engineering.require_full_refresh_gate('embed') }}
    {{ return(adapter.dispatch('embed', 'dbt_context_engineering')(input_column, model)) }}
{%- endmacro %}


{% macro default__embed(input_column, model) -%}
    {#- Gated on execute for the same reason require_ai_functions_enabled is (see
        require_prerequisites.sql): dbt's parse phase renders every model's Jinja to build the
        manifest, regardless of --select, so an unguarded raise here breaks parsing of the whole
        project the moment any one model anywhere on this adapter calls embed(), not just the
        model that does. Unlike a side-effect-only check, this macro's return value is spliced
        directly into the caller's own SELECT expression, so parse time still needs a
        syntactically valid placeholder, not an empty string. -#}
    {%- if execute -%}
        {{ exceptions.raise_compiler_error(
            "embed is not implemented for the '" ~ target.type ~ "' adapter. "
            ~ "Supported: snowflake, databricks, bigquery.") }}
    {%- endif -%}
    {{ return('null') }}
{%- endmacro %}


{% macro snowflake__embed(input_column, model) -%}
    {%- set model = model or var('embedding_model', none) -%}
    {#- execute-gated, same reasoning as default__embed above: an unguarded raise here breaks
        parsing of the whole project the moment any model anywhere calls embed() without a model
        var set, not just the model that does. -#}
    {%- if model is none -%}{%- if execute -%}{{ exceptions.raise_compiler_error("embed: set var embedding_model or pass model=.") }}{%- else -%}{%- set model = 'unset' -%}{%- endif -%}{%- endif -%}
    ai_embed('{{ model }}', {{ input_column }})
{%- endmacro %}


{% macro databricks__embed(input_column, model) -%}
    {{ dbt_context_engineering.require_databricks_serverless() }}
    {%- set model = model or var('embedding_model', none) -%}
    {#- execute-gated; see snowflake__embed above. -#}
    {%- if model is none -%}{%- if execute -%}{{ exceptions.raise_compiler_error("embed: set var embedding_model to an embedding serving endpoint, or pass model=.") }}{%- else -%}{%- set model = 'unset' -%}{%- endif -%}{%- endif -%}
    {#- ai_query returns ARRAY<DOUBLE>; vector_cosine_similarity requires ARRAY<FLOAT>. Cast so the
        stored column and query vector are both FLOAT (confirmed live 2026-07-17). -#}
    cast(ai_query('{{ model }}', {{ input_column }}) as array<float>)
{%- endmacro %}


{% macro bigquery__embed(input_column, model) -%}
    {%- set model = model or var('embedding_model', none) -%}
    {#- execute-gated; see snowflake__embed above. -#}
    {%- if model is none -%}{%- if execute -%}{{ exceptions.raise_compiler_error("embed: set var embedding_model (e.g. 'text-embedding-005') or pass model=.") }}{%- else -%}{%- set model = 'unset' -%}{%- endif -%}{%- endif -%}
    {#- AI.EMBED returns STRUCT<result ARRAY<FLOAT64>, ...>; .result is the bare vector. -#}
    (AI.EMBED(
        content => {{ input_column }},
        endpoint => '{{ model }}'
        {%- if var('bq_connection', none) %},
        connection_id => '{{ var("bq_connection") }}'
        {%- endif %}
    )).result
{%- endmacro %}
