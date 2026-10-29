{#- chunk()'s partition-level incremental mechanism. chunk() emits partition_hash and compares it
    against the stored value itself, so the caller supplies only the materialization: whole-partition
    replacement keyed on partition_key. It cannot be a merge on chunk_id, because a re-chunk can
    renumber or drop a partition's chunks, so chunk_id is not a stable identity.

    Only the replacement strategy diverges per engine:
      duckdb / snowflake   delete+insert       replaces a dirty partition's rows wholesale
      databricks           insert_overwrite    dynamic partition overwrite, same semantics
      bigquery             table               no correct incremental path exists. merge silently
                                               duplicates when a partition's chunk count shrinks,
                                               insert_overwrite cannot partition on a STRING key
                                               ("Function not found: string_trunc"), and
                                               delete+insert is unimplemented. chunk() is
                                               deterministic and zero-AI-cost, so a full rebuild
                                               costs warehouse compute only, and a downstream
                                               embed() still skips re-embedding because chunk_text
                                               is byte-identical for unchanged partitions.

    built_at is stamped here, not by chunk(), purely so assert_chunk_delta can prove an untouched
    partition was SKIPPED rather than rewritten with identical content. Same trick as
    content_hash_delta's embedded_at. A partition that was not rebuilt keeps its phase-1 timestamp. -#}

{{ config(
    materialized=('table' if target.type == 'bigquery' else 'incremental'),
    unique_key=(none if target.type == 'bigquery' else 'partition_key'),
    incremental_strategy=(
        none if target.type == 'bigquery'
        else 'insert_overwrite' if target.type == 'databricks'
        else 'delete+insert'
    ),
    partition_by=(['partition_key'] if target.type == 'databricks' else none)
) }}

with chunked as (
    {{ dbt_context_engineering.chunk(
        relation=ref('chunk_delta_units'),
        id_column='unit_id',
        order_column='turn_index',
        text_column='unit_text',
        partition_column='pk',
        target_tokens=20
    ) }}
)

select
    chunked.*,
    cast('{{ run_started_at }}' as timestamp) as built_at
from chunked
