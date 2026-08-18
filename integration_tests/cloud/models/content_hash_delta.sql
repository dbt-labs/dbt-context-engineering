{{ config(
    materialized = 'incremental',
    unique_key   = 'utterance_id',
    tags         = ['content_hash_delta'],
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
    whose source text changed. incremental_delta_predicate's content_hash_column argument catches
    it, which the plain key-existence check alone cannot (ADR-0023). On BigQuery, row_value_not_in()
    dispatches to the wrapped-tuple form, the one syntax divergence this fixture exists to force
    (the array literal below: `[1.0, 2.0, 3.0]` on Snowflake/BigQuery vs Spark SQL's
    `array(1.0, 2.0, 3.0)` on Databricks). `embedding` is a fixed stand-in literal, this exercises
    the metadata/delta mechanism on this warehouse, not a real vector, matching the duckdb fixture
    (content_hash_delta.sql). -#}

{% set fingerprint = dbt_context_engineering.embedding_fn_fingerprint(model='content-hash-delta-test') %}
{% set _embedding_literal = 'array(1.0, 2.0, 3.0)' if target.type == 'databricks' else '[1.0, 2.0, 3.0]' %}

select
    utterance_id,
    'content-hash-delta-test'                                             as model_version,
    content_hash,
    {{ _embedding_literal }}                                              as embedding,
    {{ dbt_context_engineering.embedding_dimension(_embedding_literal) }} as embedding_dimension,
    '{{ fingerprint }}'                                                   as embedding_fn_fingerprint,
    cast('{{ run_started_at }}' as timestamp)                            as embedded_at
from {{ ref('content_hash_delta_stg') }}
{% set _delta = content_hash_delta_filter() %}
{% if _delta %}where {{ _delta }}{% endif %}
