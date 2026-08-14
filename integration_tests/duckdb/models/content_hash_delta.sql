{{ config(
    materialized = 'incremental',
    unique_key   = 'utterance_id',
    pre_hook     = [
        "{{ dbt_context_engineering.guard_batch(ref('content_hash_delta_stg'), 'body',
             filter=content_hash_delta_filter()) }}",
        "{{ dbt_context_engineering.log_ai_run('embed', model_name='content-hash-delta-test',
             relation=ref('content_hash_delta_stg'), input_column='body',
             filter=content_hash_delta_filter()) }}"
    ],
    post_hook    = "{{ dbt_context_engineering.complete_ai_run('embed', model_name='content-hash-delta-test') }}"
) }}

{#- Exercises a row whose key already exists and whose embedding_fn_fingerprint still matches, but
    whose SOURCE TEXT changed. incremental_delta_predicate's content_hash_column argument catches
    it, which the plain key-existence check alone cannot (see ADR-0023).

    content_hash is computed upstream in content_hash_delta_stg, not inline here; see that
    model's comment for why: guard_batch/log_ai_run's `relation` needs an actual content_hash
    column to filter on, and a same-SELECT alias can't be filtered on in the same query anyway.

    duckdb has no embed() implementation (no duckdb__embed exists, same as the rest of the AI
    surface, LIVE-VALIDATION DEFERRED per the README). The `embedding` column here is a fixed
    stand-in literal, same precedent as ADR-0020's no-AI run-log stand-in: this test exercises the
    metadata/delta mechanism, not a real vector.

    Phase 1 (ch_edit_id=-1, the default, set on content_hash_delta_stg): baseline build, all 10
    rows, no edit. Phase 2 (ch_edit_id=<some utterance_id>, run WITHOUT --full-refresh right after
    phase 1): simulates that one row's source text changing. Expect exactly that row's
    content_hash and embedded_at to change; every other row's stay exactly as phase 1 stamped them,
    and log_ai_run's row_count for phase 2 is exactly 1. See tests/assert_content_hash_delta.sql. -#}

{% set fingerprint = dbt_context_engineering.embedding_fn_fingerprint(model='content-hash-delta-test') %}

select
    utterance_id,
    'content-hash-delta-test'                                            as model_version,
    content_hash,
    [1.0, 2.0, 3.0]                                                      as embedding,
    {{ dbt_context_engineering.embedding_dimension('[1.0, 2.0, 3.0]') }} as embedding_dimension,
    '{{ fingerprint }}'                                                  as embedding_fn_fingerprint,
    cast('{{ run_started_at }}' as timestamp)                            as embedded_at
from {{ ref('content_hash_delta_stg') }}
{% set _delta = content_hash_delta_filter() %}
{% if _delta %}where {{ _delta }}{% endif %}
