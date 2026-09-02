{#-
  dev_sample_filter(row_limit=none) -> a QUALIFY clause capping a model's input to a small random
  sample, so a dev/CI run can prove the transformation logic works without paying to run an AI
  function over the full corpus. Append it at the end of a model's SELECT, after any WHERE/GROUP
  BY, the same position ORDER BY/LIMIT would go:

    select id, text, {{ dbt_context_engineering.classify('text', ...) }} as classification
    from {{ ref('my_source') }}
    {{ dbt_context_engineering.dev_sample_filter() }}

  Gated on var('ai_sample_rows', none), following this package's vars-not-env-vars convention
  throughout (never an inferred or platform-specific env var like dbt Cloud's
  DBT_CLOUD_ENVIRONMENT_TYPE). `none` (the default) means no sampling, the full corpus runs,
  returns an empty string. Defaulting to OFF is deliberate and different from
  ai_functions_enabled's default: this macro's risk is inverted. ai_functions_enabled defaults off
  because the dangerous case is an accidental real AI call; here the dangerous case is the
  opposite, a forgotten var silently truncating a PRODUCTION run's input. Full-corpus-by-default
  costs more, not less, but never silently drops rows nobody asked to drop. Guarding against
  accidental AI spend is guard_batch's/ai_functions_enabled's job, not this macro's; this is a
  dev-experience convenience that keeps a dev/CI run far below guard_batch's ceiling in the first
  place, distinct from it, not a replacement for it.

  QUALIFY itself is portable across all four engines (duckdb, Snowflake, Databricks, BigQuery),
  confirmed live: the same qualify row_number() over (order by <random>()) <= n clause ran
  unmodified on all four. Only the random-ordering function name diverges (BigQuery: rand();
  every other target: random()), one inline check, not worth a full dispatched macro for a
  single word.

  Args:
    row_limit  overrides var('ai_sample_rows', none) for this call site specifically. Optional.
-#}
{% macro dev_sample_filter(row_limit=none) -%}
    {%- set limit = row_limit if row_limit is not none else var('ai_sample_rows', none) -%}
    {%- if limit is none -%}
        {{ return('') }}
    {%- endif -%}
    {%- set random_fn = 'rand()' if target.type == 'bigquery' else 'random()' -%}
qualify row_number() over (order by {{ random_fn }}) <= {{ limit }}
{%- endmacro %}
