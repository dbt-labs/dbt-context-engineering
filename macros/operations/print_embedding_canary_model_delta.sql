{#-
  print_embedding_canary_model_delta: run-operation ONLY, not wired into any build. Embeds
  embedding_canary's four frozen probes under two named models and prints the pairwise cosine
  similarity for each. A deliberate model swap is the exact event embedding_canary (ADR-0026)
  exists to detect, so this measures what a real drift event looks like in cosine terms without
  waiting for a provider to actually drift. Results from running this against real model pairs
  are what ground embedding_canary_similarity_threshold's (default 0.999) lower bound in
  ADR-0026's Consequences section, alongside the measured noise ceiling
  (0.999999-0.9999994).

  Reuses canary_cosine_similarity and canary_vector_to_json verbatim: model_b's vector is
  round-tripped through canary_vector_to_json into the JSON-array string
  canary_cosine_similarity's baseline_json_expr side expects, so this is the exact comparison
  embedding_canary itself makes, just against two live models instead of a live vector and a
  blessed baseline. No new dispatch needed.

    dbt run-operation print_embedding_canary_model_delta \
      --args '{model_a: <model_a>, model_b: <model_b>}'

  Only meaningful on snowflake/databricks/bigquery: embed() has no duckdb implementation and
  raises there, same as every other AI call in this package. Cost: 8 embed calls per invocation,
  run manually by a maintainer. Results belong in ADR-0026's Consequences section, not in any
  baseline or CI gate.
-#}

{% macro print_embedding_canary_model_delta(model_a, model_b) %}
    {% set dimension = var('embedding_canary_vector_dimension', none) %}
    {% set query %}
        with probes as (
            select 'pangram' as probe_id, 'the quick brown fox jumps over the lazy dog' as probe_text
            union all
            select 'short', 'hi'
            union all
            select 'long', 'The history of computing spans many decades, beginning with mechanical calculators and evolving through vacuum tubes, transistors, and integrated circuits into the modern era of cloud computing and artificial intelligence. Each generation of technology builds on the last, compounding capability while shrinking cost and size.'
            union all
            select 'unicode', 'héllo wörld 🚀 ñ ü 日本語 áéíóú'
        )
        select
            probe_id,
            {{ dbt_context_engineering.canary_cosine_similarity(
                 dbt_context_engineering.embed('probe_text', model=model_a),
                 dbt_context_engineering.canary_vector_to_json(
                     dbt_context_engineering.embed('probe_text', model=model_b)),
                 dimension) }} as similarity_across_models
        from probes
    {% endset %}
    {% set results = run_query(query) %}
    {% if execute %}
        {% for row in results.rows %}
            {{ log(row.values() | list, info=true) }}
        {% endfor %}
    {% endif %}
{% endmacro %}
