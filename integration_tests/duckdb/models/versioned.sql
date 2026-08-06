{{ config(materialized='incremental', unique_key='utterance_id') }}

{#- Exercises version_guard end to end. Stores the pinned version per row; the delta filter is
    skipped when the guard reports a version change (or first build), so a version bump re-processes
    every row and the unique_key merge replaces the old-version rows. -#}
select
    utterance_id,
    '{{ var("test_version", "v1") }}' as model_version,
    utterance_text
from {{ ref('fixture_utterances') }}
{% if not dbt_context_engineering.version_guard(var('test_version', 'v1'), 'model_version') %}
where utterance_id not in (select utterance_id from {{ this }})
{% endif %}
