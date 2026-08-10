{#-
  incremental_delta_predicate(unique_key, version=none, version_column='model_version')
    -> the SQL predicate that selects only the rows an incremental AI model will PROCESS this run,
       or `none` when the whole corpus is (re)processed (first build / --full-refresh / version bump).

  This is the single source of truth for "which rows are in this batch". Share it across all three
  places that must agree, so they can never drift:
    - the model body's delta WHERE,
    - guard_batch(..., filter=...)  (so the cost ceiling is checked against the batch, not the corpus),
    - log_ai_run(..., filter=...)   (so the run log records the batch, not the corpus).

  Gating:
    - version given  -> reprocess-everything is decided by version_guard (first build / --full-refresh
      / stored version != pinned). Use this for embedding/versioned models.
    - version omitted -> gate purely on is_incremental() (reprocess everything on first build /
      --full-refresh). Use this for a plain incremental with no model-version identity.
  Returns `none` in the reprocess-everything case, so the caller emits NO predicate and the guard/log
  correctly count the full corpus (which is what actually runs). Otherwise returns
    <unique_key> not in (select <unique_key> from <this>)
  `this` is only referenced in the delta case — never on first build, where the table doesn't exist.

  `this`, is_incremental(), and version_guard() all resolve inside a pre-/post-hook as well as the
  model body (verified on duckdb: guard_delta). Note each call issues version_guard's metadata query,
  so calling it in body + pre-hook + post-hook runs that small lookup a few times per build.
-#}
{% macro incremental_delta_predicate(unique_key, version=none, version_column='model_version') -%}
    {%- set reprocess_all = dbt_context_engineering.version_guard(version, version_column) if version is not none else (not is_incremental()) -%}
    {%- if reprocess_all -%}
        {{ return(none) }}
    {%- endif -%}
    {{ return(unique_key ~ ' not in (select ' ~ unique_key ~ ' from ' ~ this ~ ')') }}
{%- endmacro %}
