{{ config(materialized='table') }}
{#- Deterministic, zero-AI-cost: validates chunk on real Snowflake (LISTAGG / ARRAY_AGG). -#}
{{ dbt_context_engineering.chunk(
    relation=ref('fixture_utterances'),
    id_column='utterance_id',
    order_column='turn_index',
    text_column='utterance_text',
    partition_column='call_id',
    label_column='speaker',
    target_tokens=40
) }}
