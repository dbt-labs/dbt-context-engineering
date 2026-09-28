{{ config(materialized='table') }}

{#- chunk with overlap enabled (target=40, overlap=15, step=25) on the transcript seed, so a unit
    near a chunk boundary appears in two adjacent chunks.

    overlap_tokens is passed directly rather than through the project's chunk_overlap_tokens var,
    which is invocation-wide and would change every other chunking fixture here. This is the only
    model on any tier that exercises chunk()'s overlap branch, which composes the dispatched
    array_agg and string_agg. -#}
{{ dbt_context_engineering.chunk(
    relation=ref('fixture_utterances'),
    id_column='utterance_id',
    order_column='turn_index',
    text_column='utterance_text',
    partition_column='call_id',
    label_column='speaker',
    target_tokens=40,
    overlap_tokens=15
) }}
