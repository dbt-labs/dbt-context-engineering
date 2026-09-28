{{ config(
    materialized  = 'incremental',
    unique_key    = 'utterance_id',
    full_refresh  = var('allow_full_reembed', false),
    tags          = ['embed_delta'],
    pre_hook      = [
        "{{ dbt_context_engineering.guard_batch(ref('embed_delta_stg'), 'body',
             filter=embed_delta_filter()) }}",
        "{{ dbt_context_engineering.log_ai_run('embed', model_name='embed-delta-standin',
             relation=ref('embed_delta_stg'), input_column='body',
             filter=embed_delta_filter()) }}"
    ],
    post_hook     = "{{ dbt_context_engineering.complete_ai_run('embed', model_name='embed-delta-standin') }}"
) }}

{#- duckdb twin of the cloud embed_delta, on the established stand-in precedent: embed() has no
    duckdb implementation and raises there, so the embedding is a fixed literal and what this
    tier covers is the plumbing, continuously and for free. The incremental merge, the delta
    predicate, the guard, the run log, and the full_refresh config all behave identically to the
    cloud model.

    What duckdb CANNOT cover here is require_full_refresh_gate, which lives inside embed() and so
    never fires without a real AI call. That gate's live path is the cloud model only. Its raise
    path is covered separately by probe_full_refresh_gate. -#}

{% set fingerprint = dbt_context_engineering.embedding_fn_fingerprint(model='embed-delta-standin') %}

select
    utterance_id,
    'embed-delta-standin'                     as model_version,
    content_hash,
    [1.0, 2.0, 3.0]                           as embedding,
    '{{ fingerprint }}'                       as embedding_fn_fingerprint,
    cast('{{ run_started_at }}' as timestamp) as embedded_at
from {{ ref('embed_delta_stg') }}
{% set _delta = embed_delta_filter() %}
{% if _delta %}where {{ _delta }}{% endif %}
