{{ config(
    materialized  = 'incremental',
    unique_key    = 'utterance_id',
    full_refresh  = var('allow_full_reembed', false),
    tags          = ['embed_delta'],
    pre_hook      = [
        "{{ dbt_context_engineering.guard_batch(ref('embed_delta_stg'), 'body',
             filter=embed_delta_filter()) }}",
        "{{ dbt_context_engineering.log_ai_run('embed', model_name=var('embedding_model'),
             relation=ref('embed_delta_stg'), input_column='body',
             filter=embed_delta_filter()) }}"
    ],
    post_hook     = "{{ dbt_context_engineering.complete_ai_run('embed', model_name=var('embedding_model')) }}"
) }}

{#- The production shape the README presents, executed end to end for the first time: embed()
    plus content_hash plus version_guard plus incremental_delta_predicate on ONE incremental
    model, with a real billed embedding call rather than a stand-in literal.

    This is the only model on any tier that combines embed() with materialized='incremental', and
    therefore the only live path through require_full_refresh_gate, which fires only on an
    incremental model that calls an AI function. content_hash_delta covers the same delta
    mechanism with a fixed literal, so it proves the plumbing without proving that a real
    embedding call is scoped to the delta. This proves that.

    full_refresh is pinned to var('allow_full_reembed', false), which is what the gate demands and
    also what makes the model safe: a bare --full-refresh on a shared job cannot re-embed the
    whole corpus, because dbt's own full_refresh config overrides the CLI flag per node. Rebuilding
    the baseline is therefore a deliberate --vars '{allow_full_reembed: true}', not a flag someone
    passes for an unrelated model. See TESTING.md for the two-build sequence.

    Cost: 10 embed calls on the baseline build, then exactly 1 on the phase-2 build. -#}

{% set fingerprint = dbt_context_engineering.embedding_fn_fingerprint() %}

select
    utterance_id,
    '{{ var("embedding_model") }}'                            as model_version,
    content_hash,
    {{ dbt_context_engineering.embed('body') }}               as embedding,
    '{{ fingerprint }}'                                       as embedding_fn_fingerprint,
    cast('{{ run_started_at }}' as timestamp)                 as embedded_at
from {{ ref('embed_delta_stg') }}
{% set _delta = embed_delta_filter() %}
{% if _delta %}where {{ _delta }}{% endif %}
