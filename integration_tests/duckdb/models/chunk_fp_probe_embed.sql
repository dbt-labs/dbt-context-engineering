{{ config(
    materialized = 'incremental',
    unique_key   = 'chunk_id',
    pre_hook     = [
        "{{ dbt_context_engineering.guard_batch(ref('chunk_fp_probe_chunks_hashed'), 'chunk_text',
             filter=dbt_context_engineering.incremental_delta_predicate('chunk_id', content_hash_column='content_hash')) }}",
        "{{ dbt_context_engineering.log_ai_run('embed', model_name='fp-probe-test',
             relation=ref('chunk_fp_probe_chunks_hashed'), input_column='chunk_text',
             filter=dbt_context_engineering.incremental_delta_predicate('chunk_id', content_hash_column='content_hash')) }}"
    ],
    post_hook    = "{{ dbt_context_engineering.complete_ai_run('embed', model_name='fp-probe-test') }}"
) }}
{#- Stand-in embedding literal, not a real embed() call, the same precedent content_hash_delta
    uses on every tier: the thing under test is the delta/metering mechanism (does log_ai_run's
    row_count correctly read zero when chunk() rebuilds a partition but chunk_text doesn't
    change), not embed()'s own AI behavior. -#}
{% set delta = dbt_context_engineering.incremental_delta_predicate('chunk_id', content_hash_column='content_hash') %}
select
    chunk_id,
    chunk_text,
    content_hash,
    [0.1, 0.2, 0.3] as embedding,
    cast('{{ run_started_at }}' as {{ dbt.type_timestamp() }}) as embedded_at
from {{ ref('chunk_fp_probe_chunks_hashed') }}
{% if delta %}where {{ delta }}{% endif %}
