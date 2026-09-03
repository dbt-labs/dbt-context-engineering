{{ config(materialized='incremental', unique_key='partition_key', incremental_strategy='delete+insert') }}
{#- fp_probe_id_col toggles id_column between two columns holding identical values
    (chunk_fp_probe_units.unit_id / unit_id_alias), to bump chunk_fn_fingerprint without changing
    any actual output. See chunk_fp_probe_units.sql. -#}
{{ dbt_context_engineering.chunk(
    relation=ref('chunk_fp_probe_units'),
    id_column=var('fp_probe_id_col', 'unit_id'),
    order_column='turn_index',
    text_column='unit_text',
    partition_column='partition_key',
    target_tokens=40
) }}
