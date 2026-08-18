{#-
  create_vector_index — OPT-IN, run-operation ONLY (spec §5.6). Creates the engine's EXTERNAL,
  stateful, separately-billed search index/service. NEVER a model materialization.

    dbt run-operation create_vector_index --args '{name: my_idx, relation: analytics.docs, column: embedding}'

  ⚠️ These objects incur idle-serving cost and have their own lifecycle independent of dbt — dbt
  manages tables, not long-lived services. Drop them explicitly when done.

  LIVE-VALIDATION DEFERRED: creates real cloud objects; DDL assembly is probed but not executed
  here. Databricks vector search indexes are created via the Vector Search API/SDK, not SQL DDL,
  so that impl fails with guidance rather than emit fake SQL.
-#}

{% macro create_vector_index(name, relation, column, attributes=[], warehouse=none,
                                target_lag='1 day', embedding_model=none,
                                distance_type='COSINE', index_type='IVF', storing=[]) -%}
    {% do log("create_vector_index: creating an EXTERNAL, separately-billed, stateful object "
              ~ "with idle-serving cost (target='" ~ target.type ~ "'). run-operation only.", info=true) %}
    {%- set ddl = adapter.dispatch('create_vector_index', 'dbt_context_engineering')(
        name, relation, column, attributes, warehouse, target_lag, embedding_model,
        distance_type, index_type, storing) -%}
    {% if execute %}
        {% do run_query(ddl) %}
        {% do log("Created vector index/service: " ~ name, info=true) %}
    {% endif %}
    {{ return(ddl) }}
{%- endmacro %}


{% macro default__create_vector_index(name, relation, column, attributes, warehouse, target_lag, embedding_model, distance_type, index_type, storing) -%}
    {{ exceptions.raise_compiler_error(
        "create_vector_index is not implemented for the '" ~ target.type ~ "' adapter. "
        ~ "Supported: snowflake (Cortex Search service), bigquery (vector index).") }}
{%- endmacro %}


{% macro snowflake__create_vector_index(name, relation, column, attributes, warehouse, target_lag, embedding_model, distance_type, index_type, storing) -%}
    {%- if warehouse is none -%}{{ exceptions.raise_compiler_error("create_vector_index (snowflake): warehouse= is required for a Cortex Search service.") }}{%- endif -%}
create or replace cortex search service {{ name }}
    on {{ column }}
    {% if attributes %}attributes {{ attributes | join(', ') }}{% endif %}
    warehouse = {{ warehouse }}
    target_lag = '{{ target_lag }}'
    {% if embedding_model %}embedding_model = '{{ embedding_model }}'{% endif %}
    as (select * from {{ relation }})
{%- endmacro %}


{% macro bigquery__create_vector_index(name, relation, column, attributes, warehouse, target_lag, embedding_model, distance_type, index_type, storing) -%}
create or replace vector index {{ name }}
    on {{ relation }}({{ column }})
    {% if storing %}storing({{ storing | join(', ') }}){% endif %}
    options(distance_type = '{{ distance_type }}', index_type = '{{ index_type }}')
{%- endmacro %}


{% macro databricks__create_vector_index(name, relation, column, attributes, warehouse, target_lag, embedding_model, distance_type, index_type, storing) -%}
    {{ exceptions.raise_compiler_error(
        "create_vector_index: Databricks Vector Search indexes are created via the Vector Search "
        ~ "API/SDK (Delta Sync or Direct Vector index), not SQL DDL. Create the endpoint + index "
        ~ "there, then query with vector_search. See ADR-0005.") }}
{%- endmacro %}
