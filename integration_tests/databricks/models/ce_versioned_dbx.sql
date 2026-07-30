{{ config(materialized='incremental', unique_key='utterance_id', tags=['version_guard']) }}

{#- Exercises ce_version_guard on this warehouse: stores the pinned version per row; the delta
    filter is skipped on a version change, so a bump reprocesses every row (unique_key merge
    replaces the old-version rows). The delta vs. version-bump behavior is driven by the multi-run
    CI step (see .github/workflows/ci.yml `version guard sequence`), since a single build can't
    exercise it. -#}
select
    utterance_id,
    '{{ var("ce_test_version", "v1") }}' as model_version,
    utterance_text
from {{ ref('ce_fixture_utterances') }}
{% if not dbt_context_engineering.ce_version_guard(var('ce_test_version', 'v1'), 'model_version') %}
where utterance_id not in (select utterance_id from {{ this }})
{% endif %}
