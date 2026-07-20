{#-
  ce_vector_search — ranked similarity search over an embedding COLUMN (spec §5.6).

  Default is brute-force cosine over the embedding column (the task's "embeddings live as an
  ordinary column; a dedicated store is a later scale choice"). Snowflake, Databricks, and duckdb
  all expose a scalar cosine similarity, so those share one shape: score in the SELECT, ORDER BY
  score DESC, LIMIT top_k. BigQuery diverges — its VECTOR_SEARCH is a TABLE function — so it gets
  its own impl (brute-force option, no index required).

  Args:
    relation          corpus (embedding column + source id).
    embedding_column  the vector column.
    query_embedding   SQL expression for the query vector (an array literal, or a ce_embed(...) call).
    top_k             number of results (default 10).
    id_column         source id carried into results for lineage (recommended).
    select_columns    optional extra columns to return.
    filter            optional SQL predicate to restrict the candidate set (e.g. account scoping
                      for a knowledge base). Recommended for cost — searches only matching rows.

  Returns a SELECT of [id_column, select_columns..., score], ranked, top_k. score is cosine
  similarity (higher = closer). LIVE-VALIDATION DEFERRED on cloud engines; the brute-force default
  is validated on duckdb.
-#}

{% macro ce_vector_search(relation, embedding_column, query_embedding, top_k=10, id_column=none, select_columns=none, filter=none) -%}
    {{ return(adapter.dispatch('ce_vector_search', 'dbt_context_engineering')(
        relation, embedding_column, query_embedding, top_k, id_column, select_columns, filter
    )) }}
{%- endmacro %}


{#- Shared brute-force builder for engines with a scalar cosine similarity. -#}
{% macro _ce_scalar_vector_search(cosine_fn, relation, embedding_column, query_embedding, top_k, id_column, select_columns, filter) -%}
select
    {% if id_column is not none %}{{ id_column }},{% endif %}
    {% if select_columns %}{% for c in select_columns %}{{ c }},{% endfor %}{% endif %}
    {{ cosine_fn }}({{ embedding_column }}, {{ query_embedding }}) as score
from {{ relation }}
{% if filter is not none %}where {{ filter }}{% endif %}
order by score desc
limit {{ top_k }}
{%- endmacro %}


{% macro default__ce_vector_search(relation, embedding_column, query_embedding, top_k, id_column, select_columns, filter) -%}
    {{ dbt_context_engineering._ce_scalar_vector_search('array_cosine_similarity', relation, embedding_column, query_embedding, top_k, id_column, select_columns, filter) }}
{%- endmacro %}


{% macro snowflake__ce_vector_search(relation, embedding_column, query_embedding, top_k, id_column, select_columns, filter) -%}
    {{ dbt_context_engineering._ce_scalar_vector_search('vector_cosine_similarity', relation, embedding_column, query_embedding, top_k, id_column, select_columns, filter) }}
{%- endmacro %}


{% macro databricks__ce_vector_search(relation, embedding_column, query_embedding, top_k, id_column, select_columns, filter) -%}
    {{ dbt_context_engineering._ce_scalar_vector_search('vector_cosine_similarity', relation, embedding_column, query_embedding, top_k, id_column, select_columns, filter) }}
{%- endmacro %}


{% macro bigquery__ce_vector_search(relation, embedding_column, query_embedding, top_k, id_column, select_columns, filter) -%}
    {#- VECTOR_SEARCH is a table function; wrap the query vector as a one-row table. use_brute_force
        skips needing a CREATE VECTOR INDEX (the default column-embedding path). score = 1 - cosine
        distance so higher = closer, matching the scalar engines. A filter pre-restricts the base. -#}
    {%- set base = ('(select * from ' ~ relation ~ ' where ' ~ filter ~ ')') if filter is not none else ('table ' ~ relation) -%}
    select
        {% if id_column is not none %}base.{{ id_column }},{% endif %}
        {% if select_columns %}{% for c in select_columns %}base.{{ c }},{% endfor %}{% endif %}
        (1 - distance) as score
    from vector_search(
        {{ base }}, '{{ embedding_column }}',
        (select {{ query_embedding }} as {{ embedding_column }}),
        top_k => {{ top_k }},
        distance_type => 'COSINE',
        options => '{"use_brute_force": true}'
    )
{%- endmacro %}
