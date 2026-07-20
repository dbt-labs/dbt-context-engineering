{{ config(materialized='table') }}

{#- Exercises ce_chunk with overlap enabled (target=40, overlap=15, step=25) on the seed.
    A unit near a chunk boundary appears in two adjacent chunks. -#}
{{ dbt_context_engineering.ce_chunk(
    relation=ref('ce_fixture_utterances'),
    id_column='utterance_id',
    order_column='turn_index',
    text_column='utterance_text',
    partition_column='call_id',
    label_column='speaker',
    target_tokens=40,
    overlap_tokens=15
) }}
