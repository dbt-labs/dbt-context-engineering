{{ config(materialized='table') }}

{#- var-driven target_tokens so this can be rebuilt with a different chunking config to simulate
    a re-chunk. See ADR-0023's chunk_id orphaning discussion and orphan_embeddings's schema.yml
    relationships test. -#}
{{ dbt_context_engineering.chunk(
    relation=ref('fixture_utterances'),
    id_column='utterance_id',
    order_column='turn_index',
    text_column='utterance_text',
    partition_column='call_id',
    label_column='speaker',
    target_tokens=var('oc_target_tokens', 20),
    overlap_tokens=0
) }}
