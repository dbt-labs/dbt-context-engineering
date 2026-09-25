{#-
  Coverage for create_vector_index, which no model calls and no test can reach.

  It creates an EXTERNAL, separately-billed object, so a create-and-drop cycle on Snowflake and
  BigQuery belongs with the warehouse work. Three of the four implementations need no warehouse:
  two only raise, and the Snowflake and BigQuery ones only assemble a DDL string.

  What the string assertions prove: every argument is interpolated, and the optional clauses
  appear and disappear with their arguments. They do NOT prove Snowflake or BigQuery accepts the
  DDL. Only a live create-and-drop cycle does that.

  Assertions rather than singular tests because none of this is a query result. The raise probes
  are separate operations so CI can match one specific message each. A combined probe would stop
  at the first raise and say nothing about the rest.

    dbt run-operation assert_create_vector_index_ddl
-#}


{% macro _cvi_normalize(s) -%}
    {#- Collapse whitespace so reformatting a template is not a failure. -#}
    {{ return(modules.re.sub('\\s+', ' ', s).strip()) }}
{%- endmacro %}


{% macro _cvi_expect(failures, label, actual, expected) -%}
    {%- set a = _cvi_normalize(actual) -%}
    {%- set e = _cvi_normalize(expected) -%}
    {%- if a != e -%}
        {%- do failures.append(label ~ "\n    expected: " ~ e ~ "\n    actual:   " ~ a) -%}
    {%- endif -%}
{%- endmacro %}


{% macro assert_create_vector_index_ddl() %}
    {% set failures = [] %}

    {% do _cvi_expect(failures, 'snowflake__create_vector_index (all options)',
        dbt_context_engineering.snowflake__create_vector_index(
            'my_idx', 'db.sch.docs', 'embedding', ['a', 'b'], 'wh', '1 hour', 'e5', 'COSINE', 'IVF', []),
        "create or replace cortex search service my_idx on embedding attributes a, b "
        ~ "warehouse = wh target_lag = '1 hour' embedding_model = 'e5' as (select * from db.sch.docs)") %}

    {#- attributes and embedding_model must disappear entirely, not render empty. -#}
    {% do _cvi_expect(failures, 'snowflake__create_vector_index (minimal)',
        dbt_context_engineering.snowflake__create_vector_index(
            'my_idx', 'db.sch.docs', 'embedding', [], 'wh', '1 day', none, 'COSINE', 'IVF', []),
        "create or replace cortex search service my_idx on embedding "
        ~ "warehouse = wh target_lag = '1 day' as (select * from db.sch.docs)") %}

    {% do _cvi_expect(failures, 'bigquery__create_vector_index (storing)',
        dbt_context_engineering.bigquery__create_vector_index(
            'my_idx', 'db.sch.docs', 'embedding', [], none, '1 day', none, 'COSINE', 'IVF', ['a', 'b']),
        "create or replace vector index my_idx on db.sch.docs(embedding) storing(a, b) "
        ~ "options(distance_type = 'COSINE', index_type = 'IVF')") %}

    {% do _cvi_expect(failures, 'bigquery__create_vector_index (no storing)',
        dbt_context_engineering.bigquery__create_vector_index(
            'my_idx', 'db.sch.docs', 'embedding', [], none, '1 day', none, 'EUCLIDEAN', 'TREE_AH', []),
        "create or replace vector index my_idx on db.sch.docs(embedding) "
        ~ "options(distance_type = 'EUCLIDEAN', index_type = 'TREE_AH')") %}

    {% if failures %}
        {{ exceptions.raise_compiler_error(
            "assert_create_vector_index_ddl: " ~ (failures | length) ~ " implementation(s) did not "
            ~ "match.\n  " ~ (failures | join("\n  "))) }}
    {% endif %}
    {{ log("assert_create_vector_index_ddl: all rendered DDL matches.", info=true) }}
{% endmacro %}


{#- drop_vector_index's DDL-assembly half, same shape as assert_create_vector_index_ddl above:
    the Snowflake and BigQuery DDL strings, asserted as assembled text. See
    ci/coverage_matrix.py's own docstring for what an assembled-text check can and cannot prove. -#}
{% macro assert_drop_vector_index_ddl() %}
    {% set failures = [] %}

    {% do _cvi_expect(failures, 'snowflake__drop_vector_index',
        dbt_context_engineering.snowflake__drop_vector_index('my_idx', none),
        "drop cortex search service if exists my_idx") %}

    {% do _cvi_expect(failures, 'bigquery__drop_vector_index',
        dbt_context_engineering.bigquery__drop_vector_index('my_idx', 'db.sch.zz_vec_scratch'),
        "drop vector index if exists my_idx on db.sch.zz_vec_scratch") %}

    {% if failures %}
        {{ exceptions.raise_compiler_error(
            "assert_drop_vector_index_ddl: " ~ (failures | length) ~ " implementation(s) did not "
            ~ "match.\n  " ~ (failures | join("\n  "))) }}
    {% endif %}
    {{ log("assert_drop_vector_index_ddl: all rendered DDL matches.", info=true) }}
{% endmacro %}


{% macro probe_create_vector_index_default() %}
    {{ dbt_context_engineering.default__create_vector_index(
        'my_idx', 'db.sch.docs', 'embedding', [], none, '1 day', none, 'COSINE', 'IVF', []) }}
{% endmacro %}

{% macro probe_create_vector_index_databricks() %}
    {{ dbt_context_engineering.databricks__create_vector_index(
        'my_idx', 'db.sch.docs', 'embedding', [], none, '1 day', none, 'COSINE', 'IVF', []) }}
{% endmacro %}

{% macro probe_create_vector_index_snowflake_no_warehouse() %}
    {{ dbt_context_engineering.snowflake__create_vector_index(
        'my_idx', 'db.sch.docs', 'embedding', [], none, '1 day', none, 'COSINE', 'IVF', []) }}
{% endmacro %}


{% macro probe_drop_vector_index_default() %}
    {{ dbt_context_engineering.default__drop_vector_index('my_idx', none) }}
{% endmacro %}

{% macro probe_drop_vector_index_databricks() %}
    {{ dbt_context_engineering.databricks__drop_vector_index('my_idx', none) }}
{% endmacro %}

{% macro probe_drop_vector_index_bigquery_no_relation() %}
    {{ dbt_context_engineering.bigquery__drop_vector_index('my_idx', none) }}
{% endmacro %}
