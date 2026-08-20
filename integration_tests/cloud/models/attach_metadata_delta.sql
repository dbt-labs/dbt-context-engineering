{{ config(materialized='incremental', unique_key='chunk_id', tags=['attach_metadata_delta']) }}

{#- Governed incremental pattern for attach_metadata on this warehouse (ADR-0028), mirroring the
    duckdb fixture of the same name. No guard_batch/log_ai_run hooks here, unlike embed's
    content_hash_delta: attach_metadata has zero AI cost, nothing to meter or log, only
    incremental_delta_predicate + content_hash reused as-is (no version_guard either, there is no
    model-version axis for a plain SQL join to drift on). Confirmed live on Snowflake, Databricks,
    and BigQuery, 2026-08-20, including the two-phase delta scenario and, on BigQuery specifically,
    row_value_not_in's wrapped-tuple dispatch (ADR-0023) inside this model's own delta predicate. -#}

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
