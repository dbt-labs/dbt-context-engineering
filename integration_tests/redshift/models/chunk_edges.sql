{{ config(materialized='table') }}

{#- chunk() over the edge-case units, no label. target=40/overlap=0 matches ADR-0002's worked
    example so assert_chunk_edges can pin the real packing against that diagram. -#}
{{ dbt_context_engineering.chunk(
    relation=ref('chunk_edge_units'),
    id_column='unit_id',
    order_column='turn_index',
    text_column='unit_text',
    partition_column='pk',
    target_tokens=40,
    overlap_tokens=0
) }}
