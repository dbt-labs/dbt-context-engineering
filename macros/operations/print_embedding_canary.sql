{#-
  print_embedding_canary: run-operation ONLY. Prints the current embedding_canary table's rows
  (probe_id, adapter, embedding_fn_fingerprint, model_version, embedding as a JSON-array string)
  as log lines, for the re-bless workflow: when embedding_fn_fingerprint bumps (an intended
  function change), the old baseline rows simply stop matching in
  assert_embedding_canary_matches_baseline rather than failing. To re-bless, run this against
  each target that needs a new baseline and copy the printed rows into
  seeds/embedding_canary_baseline.csv, then `dbt seed`.

    dbt run-operation print_embedding_canary --target snowflake

  A dedicated operation rather than `dbt show`, so re-blessing isn't gated on manually assembling
  an inline query.
-#}

{% macro print_embedding_canary() %}
    {% set query %}
        select
            probe_id,
            adapter,
            embedding_fn_fingerprint,
            model_version,
            {{ dbt_context_engineering.canary_vector_to_json('embedding') }} as baseline_vector
        from {{ ref('embedding_canary') }}
        order by probe_id
    {% endset %}
    {% set results = run_query(query) %}
    {% if execute %}
        {% for row in results.rows %}
            {{ log(row.values() | list, info=true) }}
        {% endfor %}
    {% endif %}
{% endmacro %}
