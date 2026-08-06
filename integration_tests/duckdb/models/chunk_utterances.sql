{{ config(materialized='table') }}

{#- Exercises chunk over the synthetic transcript seed. target_tokens=40 forces multiple
    chunks on the tiny fixture so boundaries are asserted (production default is 512). -#}
{{ dbt_context_engineering.chunk(
    relation=ref('fixture_utterances'),
    id_column='utterance_id',
    order_column='turn_index',
    text_column='utterance_text',
    partition_column='call_id',
    label_column='speaker',
    target_tokens=40,
    overlap_tokens=0
) }}
