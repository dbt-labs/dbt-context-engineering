{#-
  canary_cosine_similarity(live_vector_expr, baseline_json_expr, dimension=none) -> a SQL
  expression: cosine similarity between a live embedding and a blessed baseline vector stored as
  a JSON-array string (embedding_canary_baseline.baseline_vector).

  Built for embedding_canary (models/monitoring/embedding_canary.sql, ADR-0026). Reuses the same
  cosine similarity functions vector_search (macros/retrieval/vector_search.sql, ADR-0005) already
  calls, live-validated here for the two-vector case: duckdb's array_cosine_similarity, Snowflake
  and Databricks' vector_cosine_similarity, and BigQuery's ML.DISTANCE (1 - cosine distance =
  cosine similarity; ML.DISTANCE, not the VECTOR_SEARCH table function vector_search uses, since
  this compares two known vectors rather than searching a corpus).

  Why similarity, not element-wise hashing (the mechanism this replaced): live measurement found
  the same probe embedded across separate connections lands on a small number of exact, repeating
  vector values (2-3 observed per cloud engine, not continuous per-call jitter), differing by up
  to ~0.005 on a single element. An exact-match or rounded-hash comparison has to guess how much
  of that difference is "acceptable," a threshold with no principled basis since it was never
  tied to anything the difference actually affects. Cosine similarity IS what this package's own
  retrieval already uses to decide whether two vectors are "the same" for the only thing they are
  for, ranking documents (vector_search, ADR-0005): a threshold here is grounded in "would this
  difference change a search result," not degrees of float precision that mean nothing on their
  own. Measured noise scores 0.999999-0.9999994 similarity; a real model change should score far
  below that.

  Divergence: Snowflake's VECTOR type requires a literal dimension in its own type declaration
  (confirmed live: a dynamic dimension expression is a syntax error), so `dimension` is required
  there. duckdb's fixed-size ARRAY type has the same requirement for canary_vector_hash's old
  stand-in probe. Databricks (from_json + array<float> cast, confirmed live: vector_cosine_similarity
  requires ARRAY<FLOAT>, not the ARRAY<DOUBLE> from_json produces by default -- same cast embed.sql
  already documents) and BigQuery (json_extract_array, confirmed live) both parse a variable-length
  array with no fixed dimension needed.
-#}

{% macro canary_cosine_similarity(live_vector_expr, baseline_json_expr, dimension=none) -%}
    {{ return(adapter.dispatch('canary_cosine_similarity', 'dbt_context_engineering')(live_vector_expr, baseline_json_expr, dimension)) }}
{%- endmacro %}

{#- default: duckdb. dimension is required (duckdb's ARRAY type is fixed-size; confirmed live
    that array_cosine_similarity rejects the variable-length LIST cast `::double[]` with no size). -#}
{% macro default__canary_cosine_similarity(live_vector_expr, baseline_json_expr, dimension) -%}
    array_cosine_similarity(({{ live_vector_expr }})::double[{{ dimension }}], ({{ baseline_json_expr }})::double[{{ dimension }}])
{%- endmacro %}

{#- AI_EMBED's result is already VECTOR, no cast needed on the live side; the baseline (a JSON
    string from the seed) needs PARSE_JSON then an explicit ::vector(float, dimension) cast --
    confirmed live: the dimension in that cast must be a literal, not a dynamic expression. -#}
{% macro snowflake__canary_cosine_similarity(live_vector_expr, baseline_json_expr, dimension) -%}
    {%- if dimension is none -%}
        {{ exceptions.raise_compiler_error(
            "canary_cosine_similarity: set var embedding_canary_vector_dimension to your "
            ~ "embedding_model's output dimension. Snowflake's VECTOR type requires a literal "
            ~ "dimension (confirmed live: a dynamic expression is a syntax error)."
        ) }}
    {%- endif -%}
    vector_cosine_similarity({{ live_vector_expr }}, parse_json({{ baseline_json_expr }})::vector(float, {{ dimension }}))
{%- endmacro %}

{% macro databricks__canary_cosine_similarity(live_vector_expr, baseline_json_expr, dimension) -%}
    vector_cosine_similarity(
        cast({{ live_vector_expr }} as array<float>),
        cast(from_json({{ baseline_json_expr }}, 'array<double>') as array<float>)
    )
{%- endmacro %}

{#- ML.DISTANCE returns cosine DISTANCE (0 = identical); 1 - distance matches the similarity scale
    (1 = identical) every other branch and vector_search's score column already use. -#}
{% macro bigquery__canary_cosine_similarity(live_vector_expr, baseline_json_expr, dimension) -%}
    (1 - ML.DISTANCE(
        {{ live_vector_expr }},
        (select array_agg(cast(x as float64)) from unnest(json_extract_array({{ baseline_json_expr }})) as x),
        'COSINE'
    ))
{%- endmacro %}

{#-
  canary_vector_to_json(vector_expression) -> a SQL expression: vector_expression serialized as a
  JSON-array string ("[0.1,0.2,...]"), the exact format embedding_canary_baseline.baseline_vector
  stores and canary_cosine_similarity's baseline_json_expr parses. Used only by
  print_embedding_canary (the re-bless workflow) to turn a live observed vector back into
  something pasteable into the seed; the comparison path never needs this, it reads the seed's
  string directly.
-#}
{% macro canary_vector_to_json(vector_expression) -%}
    {{ return(adapter.dispatch('canary_vector_to_json', 'dbt_context_engineering')(vector_expression)) }}
{%- endmacro %}

{% macro default__canary_vector_to_json(vector_expression) -%}
    to_json({{ vector_expression }})
{%- endmacro %}

{#- embedding is VECTOR; TO_JSON needs ARRAY, same cast canary_cosine_similarity's Snowflake
    branch is exempt from only because AI_EMBED's result already lines up with what
    vector_cosine_similarity expects -- serializing to text has no such shortcut. -#}
{% macro snowflake__canary_vector_to_json(vector_expression) -%}
    to_json(({{ vector_expression }})::array)
{%- endmacro %}

{% macro databricks__canary_vector_to_json(vector_expression) -%}
    to_json({{ vector_expression }})
{%- endmacro %}

{% macro bigquery__canary_vector_to_json(vector_expression) -%}
    to_json_string({{ vector_expression }})
{%- endmacro %}
