{{ config(materialized='table') }}

{#- var-driven target_tokens (unlike chunk_utterances.sql's hardcoded 40) specifically so this can
    be rebuilt with a DIFFERENT chunking config to simulate re-chunking shifting chunk
    boundaries. See ADR-0023's Consequences section on chunk_id orphaning, and
    orphan_embeddings.yml's relationships test. -#}
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
