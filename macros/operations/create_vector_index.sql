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
    {#- Cortex Search auto-embeds `column` itself, so `column` must be TEXT, not a pre-computed
        VECTOR (confirmed live: passing an embedding column here raises a TO_VARCHAR cast error).
        The base query is also restricted to `column` and `attributes`, never `select *`,
        confirmed live: `select *` fails with "Invalid column type VECTOR(...) for source query
        column" the moment the relation carries any VECTOR column, which most real callers of
        this macro will, since the whole reason to reach for a managed index is a corpus that
        already has embeddings sitting next to the text. Selecting only what the service
        declares (the search column plus any filter attributes) is correct anyway: nothing else
        the service returns needs to be there. -#}
create or replace cortex search service {{ name }}
    on {{ column }}
    {% if attributes %}attributes {{ attributes | join(', ') }}{% endif %}
    warehouse = {{ warehouse }}
    target_lag = '{{ target_lag }}'
    {% if embedding_model %}embedding_model = '{{ embedding_model }}'{% endif %}
    as (select {{ column }}{% if attributes %}, {{ attributes | join(', ') }}{% endif %} from {{ relation }})
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


{#-
  drop_vector_index — the mandatory counterpart to create_vector_index. These objects are
  external, separately-billed, and idle-serving, so a create-and-drop validation cycle must end
  with this or it leaves something billing. OPT-IN, run-operation ONLY, same as create.

    dbt run-operation drop_vector_index --args '{name: my_idx}' --target snowflake

  Dispatched the same way create_vector_index is: which implementation fires depends on the
  connection's target, not on an argument, so --target on the CLI is what selects it.
-#}

{% macro drop_vector_index(name, relation=none) -%}
    {%- set ddl = adapter.dispatch('drop_vector_index', 'dbt_context_engineering')(name, relation) -%}
    {% if execute %}
        {% do run_query(ddl) %}
        {% do log("Dropped vector index/service: " ~ name, info=true) %}
    {% endif %}
    {{ return(ddl) }}
{%- endmacro %}


{% macro default__drop_vector_index(name, relation) -%}
    {{ exceptions.raise_compiler_error(
        "drop_vector_index is not implemented for the '" ~ target.type ~ "' adapter. "
        ~ "Supported: snowflake (Cortex Search service), bigquery (vector index).") }}
{%- endmacro %}


{% macro snowflake__drop_vector_index(name, relation) -%}
drop cortex search service if exists {{ name }}
{%- endmacro %}


{#- BigQuery's DROP VECTOR INDEX requires the ON <table> clause; confirmed live that omitting it
    raises "DROP VECTOR INDEX statement must have the ON <table> clause", unlike CREATE VECTOR
    INDEX ... ON <table>(<column>) which names the table on the CREATE side. relation is required
    here for that reason, not optional the way it is for Snowflake, where DROP CORTEX SEARCH
    SERVICE takes only the service name. -#}
{% macro bigquery__drop_vector_index(name, relation) -%}
    {%- if relation is none -%}{{ exceptions.raise_compiler_error("drop_vector_index (bigquery): relation= is required, confirmed live that BigQuery's DROP VECTOR INDEX needs an ON <table> clause.") }}{%- endif -%}
drop vector index if exists {{ name }} on {{ relation }}
{%- endmacro %}


{% macro databricks__drop_vector_index(name, relation) -%}
    {{ exceptions.raise_compiler_error(
        "drop_vector_index: Databricks Vector Search indexes are managed via the Vector Search "
        ~ "API/SDK, not SQL DDL. Drop the endpoint/index there. See ADR-0005.") }}
{%- endmacro %}
