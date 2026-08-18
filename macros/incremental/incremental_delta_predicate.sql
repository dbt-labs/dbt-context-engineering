{#-
  incremental_delta_predicate(unique_key, version=none, version_column='model_version',
                               content_hash_column=none)
    -> the SQL predicate that selects only the rows an incremental AI model will PROCESS this run,
       or `none` when the whole corpus is (re)processed (first build / --full-refresh / version bump).

  This is the single source of truth for "which rows are in this batch". Share it across all three
  places that must agree, so they can never drift:
    - the model body's delta WHERE,
    - guard_batch(..., filter=...)  (so the cost ceiling is checked against the batch, not the corpus),
    - log_ai_run(..., filter=...)   (so the run log records the batch, not the corpus).

  Gating:
    - version given: reprocess-everything is decided by version_guard (first build, --full-refresh,
      or stored version != pinned). Use this for embedding/versioned models. For the embedding
      pattern specifically, pass version=embedding_fn_fingerprint(...) and
      version_column='embedding_fn_fingerprint'; version_guard needs no code change to do this, it
      already compares an arbitrary (value, column) pair.
    - version omitted: gate purely on is_incremental() (reprocess everything on first build or
      --full-refresh). Use this for a plain incremental with no model-version identity.
  Returns `none` in the reprocess-everything case, so the caller emits NO predicate and the guard/log
  correctly count the full corpus (which is what actually runs). Otherwise returns
    <unique_key> not in (select <unique_key> from <this>)
  optionally OR'd with a content-hash comparison when content_hash_column is given (see below).
  `this` is only referenced in the delta case, never on first build, where the table doesn't exist.

  content_hash_column: the finer-grained half of the delta this macro can't see on its own, a row
  whose key already exists and whose version/fingerprint still matches, but whose source text
  changed. Pass the column name holding the row's content hash (e.g. 'content_hash'), computed
  identically on both sides via content_hash(). Adds a row-value comparison, dispatched via
  row_value_not_in() (macros/incremental/row_value_not_in.sql, ADR-0023), OR'd onto the
  key-existence check, not replacing it. Extended in place rather than as a sibling macro so
  guard_batch, log_ai_run, and the model body's own WHERE keep calling this one macro.

  A brand-new key still enters the delta regardless of its hash (the key-existence check alone is
  true). An existing key whose current hash is null needs no separate handling: the row-value
  comparison against null evaluates to null (duckdb) or false (Snowflake, Databricks) under
  three-valued logic, so WHERE excludes it and the row's last-known-good state stays frozen. See
  ADR-0023 for the full reasoning behind this shape, including why it is a row-value NOT IN rather
  than a correlated subquery.

  `this`, is_incremental(), and version_guard() all resolve inside a pre-/post-hook as well as the
  model body (see guard_delta in integration_tests/duckdb). Each call issues version_guard's
  metadata query, so calling it in body + pre-hook + post-hook runs that small lookup a few times
  per build.
-#}
{% macro incremental_delta_predicate(unique_key, version=none, version_column='model_version', content_hash_column=none) -%}
    {%- set reprocess_all = dbt_context_engineering.version_guard(version, version_column) if version is not none else (not is_incremental()) -%}
    {%- if reprocess_all -%}
        {{ return(none) }}
    {%- endif -%}

    {%- set predicate = unique_key ~ ' not in (select ' ~ unique_key ~ ' from ' ~ this ~ ')' -%}
    {%- if content_hash_column is not none -%}
        {%- set predicate = predicate ~ ' or ' ~ dbt_context_engineering.row_value_not_in(
            [unique_key, content_hash_column], this) -%}
    {%- endif -%}
    {{ return(predicate) }}
{%- endmacro %}
