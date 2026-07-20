{#-
  ce_embed — row-level embedding of a text column (spec §5.1). No prompt/schema; the embedding
  model is pinned via var ce_embedding_model (a corpus embedded by one model cannot be searched
  by another — see Phase 5). LIVE-VALIDATION DEFERRED.

  Scalar on all three engines: Snowflake AI_EMBED, Databricks ai_query (serving endpoint), and
  BigQuery AI.EMBED (the newer AI.* GA family — endpoint + connection_id inline, no CREATE MODEL).
  The older BigQuery ML.GENERATE_EMBEDDING is a TABLE function and is intentionally not used here.
-#}

{% macro ce_embed(input_column, model=none) -%}
    {{ return(adapter.dispatch('ce_embed', 'dbt_context_engineering')(input_column, model)) }}
{%- endmacro %}


{% macro default__ce_embed(input_column, model) -%}
    {{ exceptions.raise_compiler_error(
        "ce_embed is not implemented for the '" ~ target.type ~ "' adapter. "
        ~ "Supported: snowflake, databricks, bigquery.") }}
{%- endmacro %}


{% macro snowflake__ce_embed(input_column, model) -%}
    {%- set model = model or var('ce_embedding_model', none) -%}
    {%- if model is none -%}{{ exceptions.raise_compiler_error("ce_embed: set var ce_embedding_model or pass model=.") }}{%- endif -%}
    ai_embed('{{ model }}', {{ input_column }})
{%- endmacro %}


{% macro databricks__ce_embed(input_column, model) -%}
    {{ dbt_context_engineering.ce_require_databricks_serverless() }}
    {%- set model = model or var('ce_embedding_model', none) -%}
    {%- if model is none -%}{{ exceptions.raise_compiler_error("ce_embed: set var ce_embedding_model to an embedding serving endpoint, or pass model=.") }}{%- endif -%}
    {#- ai_query returns ARRAY<DOUBLE>; vector_cosine_similarity requires ARRAY<FLOAT>. Cast so the
        stored column and query vector are both FLOAT (confirmed live 2026-07-17). -#}
    cast(ai_query('{{ model }}', {{ input_column }}) as array<float>)
{%- endmacro %}


{% macro bigquery__ce_embed(input_column, model) -%}
    {%- set model = model or var('ce_embedding_model', none) -%}
    {%- if model is none -%}{{ exceptions.raise_compiler_error("ce_embed: set var ce_embedding_model (e.g. 'text-embedding-005') or pass model=.") }}{%- endif -%}
    {#- AI.EMBED returns STRUCT<result ARRAY<FLOAT64>, ...>; .result is the bare vector. -#}
    (AI.EMBED(
        content => {{ input_column }},
        endpoint => '{{ model }}'
        {%- if var('ce_bq_connection', none) %},
        connection_id => '{{ var("ce_bq_connection") }}'
        {%- endif %}
    )).result
{%- endmacro %}
