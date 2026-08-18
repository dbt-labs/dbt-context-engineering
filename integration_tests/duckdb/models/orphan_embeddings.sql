{{ config(
    materialized = 'incremental',
    unique_key   = 'chunk_id'
) }}

{#- Exercises the chunk_id orphaning gap: chunk_id is derived from
    dense_rank() over a cumulative token sum within a partition, so a re-chunk (here, simulated by
    rebuilding orphan_chunks with a different oc_target_tokens, --full-refresh, a table
    materialization) can make a chunk_id that used to exist simply not be produced anymore, not go
    null, absent. Nothing in incremental_delta_predicate or the merge removes a row whose key is no
    longer in the source query, that's not a bug to fix here (would mean building deletion logic
    this package has deliberately avoided elsewhere, ADR-0004), it's surfaced instead: see this
    model's .yml, a `relationships` test against orphan_chunks.chunk_id, same "fail loudly instead
    of silently wrong" pattern attach_metadata's uniqueness test already uses. -#}

{% set _delta = dbt_context_engineering.incremental_delta_predicate('chunk_id') %}

select chunk_id, chunk_text
from {{ ref('orphan_chunks') }}
{% if _delta %}where {{ _delta }}{% endif %}
