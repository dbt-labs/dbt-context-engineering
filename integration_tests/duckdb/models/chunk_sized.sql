{{ config(materialized='table') }}

{#- Host for no_oversized_chunks, a generic test this package ships and the README tells
    consumers to attach.

    A dedicated fixture rather than an existing chunking model, because the test needs both halves
    and no existing model gives them. The models with a fixed target exercise only whichever half
    their corpus happens to land on, and orphan_chunks already carries 4 oversized chunks at its
    default target (its job is re-chunk orphaning, not size). Here the target is var-driven and its
    default is comfortably above the largest utterance, so every build proves the test passes on a
    corpus that fits, and CI re-runs it with a target of 3 and requires it to fail. -#}
{{ dbt_context_engineering.chunk(
    relation=ref('fixture_utterances'),
    id_column='utterance_id',
    order_column='turn_index',
    text_column='utterance_text',
    partition_column='call_id',
    target_tokens=var('sized_target_tokens', 200),
    overlap_tokens=0
) }}
