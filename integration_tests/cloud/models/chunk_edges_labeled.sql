{{ config(materialized='table') }}

{#- Same units and budget as chunk_edges, but WITH a label column. The point is the null_mid
    partition: `label || ': ' || text` is NULL on every engine when text is NULL, so without a
    coalesce the unit vanishes from chunk_text and takes its speaker attribution with it, while
    source_rows still counts it. assert_chunk_null_lineage pins that it survives as "S: ". -#}
{{ dbt_context_engineering.chunk(
    relation=ref('chunk_edge_units'),
    id_column='unit_id',
    order_column='turn_index',
    text_column='unit_text',
    partition_column='pk',
    label_column='speaker',
    target_tokens=40,
    overlap_tokens=0
) }}
