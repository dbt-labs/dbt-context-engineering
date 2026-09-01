{{ config(materialized='incremental', unique_key='chunk_id') }}

{#- attach_metadata's own macro-owned incremental mechanism. No caller-assembled hash, no
    caller-supplied delta filter: attach_metadata computes content_hash itself from
    metadata_columns and decides its own delta via incremental_delta_predicate('chunk_id',
    content_hash_column='content_hash') internally. Plain merge on chunk_id, no
    incremental_strategy override, unlike chunk(): attach_metadata never invents or renumbers
    chunk_id, so a chunk_id it receives matches at most one stored row.

    built_at is stamped here, not inside attach_metadata, purely so assert_attach_metadata_delta
    can prove an untouched chunk was SKIPPED rather than rewritten with identical content. Same
    trick as chunk_delta and content_hash_delta's own built_at/embedded_at columns. -#}

with attached as (
    {{ dbt_context_engineering.attach_metadata(
        chunks_relation=ref('chunk_docs'),
        metadata_relation=ref('attach_metadata_delta_meta_stg'),
        metadata_key_column='document_id',
        metadata_columns=['title', 'citation_url']
    ) }}
)

select
    attached.*,
    cast('{{ run_started_at }}' as timestamp) as built_at
from attached
