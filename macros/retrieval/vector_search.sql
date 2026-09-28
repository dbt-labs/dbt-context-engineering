{#-
  vector_search — ranked similarity search over an embedding COLUMN (spec §5.6).

  Default is brute-force cosine over the embedding column (the task's "embeddings live as an
  ordinary column; a dedicated store is a later scale choice"). Snowflake, Databricks, and duckdb
  all expose a scalar cosine similarity, so those share one shape: score in the SELECT, ORDER BY
  score DESC, LIMIT top_k. BigQuery diverges — its VECTOR_SEARCH is a TABLE function — so it gets
  its own impl (brute-force option, no index required).

  Args:
    relation          corpus (embedding column + source id).
    embedding_column  the vector column.
    query_embedding   SQL expression for the query vector (an array literal, or a embed(...) call).
    top_k             number of results (default 10).
    id_column         source id carried into results for lineage (recommended).
    select_columns    optional extra columns to return.
    filter            optional SQL predicate to restrict the candidate set (e.g. account scoping
                      for a knowledge base). Recommended for cost — searches only matching rows.

  Returns a SELECT of [id_column, select_columns..., score], ranked, top_k. score is cosine
  similarity (higher = closer).

  TIE BEHAVIOR DIVERGES ON BIGQUERY. On duckdb, Snowflake and Databricks the id_column secondary
  sort decides which of several equally-scoring rows crosses the top_k cutoff, so the result is
  reproducible run to run. On BigQuery it does not, because VECTOR_SEARCH is a table function
  that picks its own top_k before any ORDER BY applies. Measured on repeated runs over identical
  data, the boundary row varies. Ordering of the returned rows is stable everywhere, and the rows
  that vary are by definition equally similar to the query, so ranking quality is unaffected. What
  is affected is reproducibility: a model materialized from a BigQuery search whose cutoff splits
  a tie can change with no data change, which also moves any content_hash computed over it. A
  BigQuery consumer who needs a reproducible cutoff should request more rows than needed and apply
  their own ORDER BY and LIMIT, or deduplicate the corpus before embedding. Covered by
  assert_vector_search_tiebreak and assert_vector_search_tie_ordering in both integration projects.
-#}

{% macro vector_search(relation, embedding_column, query_embedding, top_k=10, id_column=none, select_columns=none, filter=none) -%}
    {{ return(adapter.dispatch('vector_search', 'dbt_context_engineering')(
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
{#- Secondary sort on id_column so rows tied at the top_k cutoff are stable across runs.
    Near-duplicate chunks routinely tie on score, and without this the boundary row is
    nondeterministic. The engine applies this ORDER BY before LIMIT, so it governs WHICH tied row
    crosses the cutoff, not just the order of the result. bigquery__vector_search cannot offer the
    same guarantee; see its own note. -#}
order by score desc{% if id_column is not none %}, {{ id_column }}{% endif %}
limit {{ top_k }}
{%- endmacro %}


{% macro default__vector_search(relation, embedding_column, query_embedding, top_k, id_column, select_columns, filter) -%}
    {{ dbt_context_engineering._ce_scalar_vector_search('array_cosine_similarity', relation, embedding_column, query_embedding, top_k, id_column, select_columns, filter) }}
{%- endmacro %}


{% macro snowflake__vector_search(relation, embedding_column, query_embedding, top_k, id_column, select_columns, filter) -%}
    {{ dbt_context_engineering._ce_scalar_vector_search('vector_cosine_similarity', relation, embedding_column, query_embedding, top_k, id_column, select_columns, filter) }}
{%- endmacro %}


{% macro databricks__vector_search(relation, embedding_column, query_embedding, top_k, id_column, select_columns, filter) -%}
    {{ dbt_context_engineering._ce_scalar_vector_search('vector_cosine_similarity', relation, embedding_column, query_embedding, top_k, id_column, select_columns, filter) }}
{%- endmacro %}


{% macro bigquery__vector_search(relation, embedding_column, query_embedding, top_k, id_column, select_columns, filter) -%}
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
    {#- Stable output ordering, with id_column as the tiebreaker to match the scalar engines. This
        orders the returned set deterministically, and that is all it can do here: the
        VECTOR_SEARCH table function has already picked which top_k rows come back, so a tie AT
        the cutoff is resolved inside it, arbitrarily and not stably across runs. See the
        macro docstring above for the consumer-facing consequence. -#}
    order by score desc{% if id_column is not none %}, base.{{ id_column }}{% endif %}
{%- endmacro %}
