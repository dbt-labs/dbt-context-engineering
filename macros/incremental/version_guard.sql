{#-
  version_guard(pinned_version, version_column='model_version') -> bool.

  Returns True when an incremental model must REPROCESS ALL rows — i.e. first build /
  `--full-refresh`, or the version stored in the table differs from `pinned_version`. Returns
  False when it can safely process just the incremental delta. Critical for embeddings: a corpus
  embedded by one model version cannot be searched by another, so a version bump must re-embed
  everything (spec §5.5, non-goal §2 = no custom materialization).

  Why a runtime boolean and not `config(full_refresh=…)`: config is evaluated at PARSE time, but
  the stored version can only be read from the table at RUN time. So the guard drives the model's
  incremental WHERE instead. Pair with a `unique_key` so a reprocess merges/replaces rather than
  duplicates. Usage:

    {{ config(materialized='incremental', unique_key='doc_id') }}
    select doc_id, '{{ var("embedding_model") }}' as model_version, ...
    from {{ ref('docs') }}
    {% if not dbt_context_engineering.version_guard(var('embedding_model')) %}
    where doc_id not in (select doc_id from {{ this }})   -- delta only; skipped on version change
    {% endif %}
-#}
{% macro version_guard(pinned_version, version_column='model_version') -%}
    {%- if not is_incremental() -%}
        {{ return(true) }}   {#- first build or --full-refresh: process everything -#}
    {%- endif -%}
    {%- if not execute -%}
        {{ return(false) }}  {#- parse time: assume the incremental delta path -#}
    {%- endif -%}
    {#- Adoption path: pointing the package at a PRE-EXISTING incremental table that predates version
        stamping — the table exists but has no version_column. Reading it would raise an opaque
        "column does not exist". There is no stored version to trust, so the safe direction is to
        reprocess everything (this run adds/stamps the column and the unique_key merge replaces rows). -#}
    {%- set col_names = adapter.get_columns_in_relation(this) | map(attribute='name') | map('lower') | list -%}
    {%- if version_column | lower not in col_names -%}
        {{ return(true) }}
    {%- endif -%}
    {%- set stored = run_query('select distinct ' ~ version_column ~ ' as v from ' ~ this).columns[0].values() -%}
    {%- set mismatched = stored | reject('equalto', pinned_version) | list -%}
    {#- reprocess if the table is empty or holds any version other than the pinned one -#}
    {{ return(((stored | length) == 0) or ((mismatched | length) > 0)) }}
{%- endmacro %}
