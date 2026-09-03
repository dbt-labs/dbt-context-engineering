{#-
  create_ai_run_log_table() -> bootstraps ai_run_log exactly once, serially, before any
  threaded model execution begins. Meant to be wired into a consumer's own on-run-start hook:

    on-run-start:
      - "-- depends_on: {{ ref('ai_run_log') }}\n{{ dbt_context_engineering.create_ai_run_log_table() }}"

  The `-- depends_on:` line is required, not decorative. dbt statically scans a hook string for
  ref()/source() calls to build the DAG dependency edge; this macro's own ref('ai_run_log')
  below is inside a Jinja if block, which that static scanner does not see. Omitting the
  depends_on hint produces a real compilation error: "dbt was unable to infer all dependencies
  for the ref() ... typically happens when ref() is placed within a conditional block."
  The hinted ref() itself never executes, it is inside a SQL comment; it exists only to register
  the dependency edge.

  Why this needs to exist at all: log_ai_run() used to self-create ai_run_log lazily, the
  first time it fired against a target where the table didn't exist, so a bare
  `dbt run --select <one_model>` never needed to also select ai_run_log. That convenience is
  exactly what raced under concurrency: two or more AI-calling models selected in the same
  invocation, with no dependency between them, run on different threads, and each one's
  log_ai_run pre-hook independently tries to CREATE TABLE IF NOT EXISTS against the same
  target. Confirmed live: on Databricks, [DELTA_CONCURRENT_APPEND.WITHOUT_HINT] aborted 7 of 8
  concurrent attempts; on BigQuery, a 429 "too many table update operations" rate limit
  rejected redundant concurrent bootstrap attempts (confirmed via
  INFORMATION_SCHEMA.JOBS_BY_USER against the exact failing statement). log_ai_run() no longer
  self-creates; it now assumes ai_run_log already exists, the same way every other ref()-based
  dependency in this package is expected to already exist by the time a hook runs.

  on-run-start hooks run once, serially, strictly before any node (model, seed, snapshot)
  begins executing, on every dbt version this package supports. That serialization, not the
  ai_functions_enabled check below, is what makes this race-free: there is no other writer to
  race, because nothing else has started yet.

  Why this checks ai_functions_enabled at all, given that var is about gating AI SPEND, not
  about concurrency safety: creating ai_run_log unconditionally on every invocation, including
  ones that will never call an AI function this run, is pure overhead for no benefit. Skipping
  the check entirely (always bootstrap) would still be correct, just wasteful on every
  structural-only run. This is an efficiency decision layered onto the safety one, not a second
  safety mechanism; a project that never sets ai_functions_enabled true never needed
  ai_run_log in the first place.

  This is the same manual-wiring shape dbt_artifacts requires for its own on-run-end hook
  (upload_results): a package cannot inject a hook into a consuming project's own
  dbt_project.yml, hooks declared in a package's own dbt_project.yml are not inherited by
  projects that install it. One line in the consumer's own dbt_project.yml, calling a macro
  this package ships, same as that precedent.
-#}
{% macro create_ai_run_log_table() -%}
    {%- if var('ai_functions_enabled', false) and execute -%}
        {%- do run_query(
            "create table if not exists " ~ ref('ai_run_log') ~ " as (" ~ dbt_context_engineering.ai_run_log_columns_sql() ~ ")"
        ) -%}
    {%- endif -%}
    {#- The CREATE above runs via run_query(), a separate statement, not this return value.
        This macro is meant to be used standalone as an entire on-run-start hook, unlike the
        removed ensure_ai_run_log_exists() it replaces, which was always concatenated inline
        into log_ai_run's own larger INSERT statement. An empty string is a valid fragment to
        concatenate into something else; it is not valid SQL on its own, so a hook that uses
        only this macro needs a real no-op statement here. -#}
    {{ return('select 1') }}
{%- endmacro %}
