{{ config(materialized='incremental', unique_key='utterance_id', on_schema_change='sync_all_columns') }}

{#- Adoption path for version_guard (finding #9). Two shapes gated by a var so a sequential build can
    reproduce "pointing the package at a PRE-EXISTING incremental table that predates version stamping":
      run 1 (vg_legacy=true, --full-refresh): create the table WITHOUT model_version (legacy shape).
      run 2 (vg_legacy=false):                first version_guard run against that column-less table.
    Old version_guard read model_version unconditionally -> opaque "column does not exist". Fixed
    version detects the missing column and returns true (reprocess all), stamping the column this run.
    assert_vg_adopt confirms run 2 succeeds and every row now carries the pinned version. -#}
{% if var('vg_legacy', false) %}
select utterance_id, utterance_text
from {{ ref('fixture_utterances') }}
{% else %}
{% set reprocess = dbt_context_engineering.version_guard(var('vg_ver', 'v1'), 'model_version') %}
select
    utterance_id,
    '{{ var("vg_ver", "v1") }}' as model_version,
    utterance_text
from {{ ref('fixture_utterances') }}
{% if not reprocess %}where utterance_id not in (select utterance_id from {{ this }}){% endif %}
{% endif %}
