{{ config(
    materialized='incremental',
    unique_key='utterance_id',
    pre_hook="{{ dbt_context_engineering.guard_batch(
        ref('fixture_utterances'),
        'utterance_text',
        filter=dbt_context_engineering.incremental_delta_predicate('utterance_id', var('gd_version', 'v1'))
    ) }}"
) }}

{#- Faithful test of the documented governed-incremental pattern AND of incremental_delta_predicate():
    the body, the guard's filter, and (in logged models) the log all take their delta from the ONE
    helper, so they can't drift. Proves `this` / version_guard() resolve inside a pre-hook. CI checks:
      - steady-state incremental (same version) with max_batch_rows=3 PASSES — the helper returns the
        delta predicate (referencing `this`), scoping the count to the 0-row delta; the full 10 would trip.
      - a version bump with max_batch_rows=3 TRIPS — the helper returns none, so the whole 10-row corpus
        is guarded before the merge re-embeds it. Matches the body dropping its WHERE.
    On first build version_guard is True (helper returns none), so `this` is never referenced before the
    table exists. -#}
{% set _delta = dbt_context_engineering.incremental_delta_predicate('utterance_id', var('gd_version', 'v1')) %}
select
    utterance_id,
    '{{ var("gd_version", "v1") }}' as model_version,
    utterance_text
from {{ ref('fixture_utterances') }}
{% if _delta %}where {{ _delta }}{% endif %}
