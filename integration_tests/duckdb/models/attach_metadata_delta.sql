{{ config(materialized='incremental', unique_key='chunk_id') }}

{#- Governed incremental pattern for attach_metadata (PR: incremental recompute for the metadata
    layer, closing half of DEFERRED.md #2). attach_metadata's output for a given chunk_id is a
    pure function of that one chunk row plus its one metadata row, the same shape embed()'s
    content_hash delta already solved (ADR-0023) -- so this reuses incremental_delta_predicate and
    content_hash as-is, no change to attach_metadata itself.

    No version_guard / embedding_fn_fingerprint here: attach_metadata has no model-version concept
    to bump (it's zero-AI-cost, plain SQL -- there's no "the function changed" axis the way an
    embedding model swap is), so incremental_delta_predicate is called with version omitted, which
    gates reprocess-all purely on is_incremental() (first build / --full-refresh).

    content_hash covers chunk_text AND every metadata_columns value, so it catches a change on
    EITHER side: chunk's own text changing (already covered by chunk_docs upstream, but the
    hash still reflects it) or the metadata changing while the chunk text doesn't, the gap this
    model exists to close. attach_metadata_delta_meta_stg simulates that second case with a
    var-driven title edit, isolated from chunk_docs so the chunk text genuinely does not change.

    attach_metadata's own macro output is a complete SELECT (it ends in its own ORDER BY); it is
    wrapped here as a nested CTE ("attached"), not the top-level statement, so content_hash can be
    computed as a real column in a later CTE and filtered in the final SELECT's WHERE, never a
    same-SELECT alias (the BigQuery trap chunk.sql's own comments already document). Confirmed live
    on duckdb that a macro-generated "WITH ... SELECT ... ORDER BY" body composes cleanly as one
    CTE inside a larger WITH. -#}

{% set str_t = dbt.type_string() %}

with attached as (
    {{ dbt_context_engineering.attach_metadata(
        chunks_relation=ref('chunk_docs'),
        metadata_relation=ref('attach_metadata_delta_meta_stg'),
        metadata_key_column='document_id',
        metadata_columns=['title', 'citation_url']
    ) }}
),

hashed as (
    select
        *,
        {{ dbt_context_engineering.content_hash(
            "chunk_text || '|' || coalesce(cast(title as " ~ str_t ~ "), '') || '|' || coalesce(cast(citation_url as " ~ str_t ~ "), '')"
        ) }} as content_hash,
        cast('{{ run_started_at }}' as timestamp) as processed_at
    from attached
)

select * from hashed
{% set delta = dbt_context_engineering.incremental_delta_predicate('chunk_id', content_hash_column='content_hash') %}
{% if delta %}where {{ delta }}{% endif %}
