{{ config(
    materialized = 'incremental',
    unique_key   = 'chunk_id'
) }}

{#- Exercises the chunk_id orphaning gap: chunk_id is derived from dense_rank() over a cumulative
    token sum within a partition, so a re-chunk can make a chunk_id that used to exist simply not
    be produced anymore, not go null, absent. Nothing in incremental_delta_predicate or the merge
    removes a row whose key is no longer in the source query; that's surfaced with a relationships
    test (see this model's .yml) rather than deletion logic (ADR-0004, ADR-0023). -#}

{% set _delta = dbt_context_engineering.incremental_delta_predicate('chunk_id') %}

select chunk_id, chunk_text
from {{ ref('orphan_chunks') }}
{% if _delta %}where {{ _delta }}{% endif %}
