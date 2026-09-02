{{ config(materialized='view') }}
{#- content_hash needs a real column, not a same-SELECT alias (the BigQuery trap chunk.sql's own
    comments document), so guard_batch/log_ai_run's relation can filter on it. -#}
select
    chunk_id,
    partition_key,
    chunk_text,
    {{ dbt_context_engineering.content_hash('chunk_text') }} as content_hash
from {{ ref('chunk_fp_probe_chunks') }}
