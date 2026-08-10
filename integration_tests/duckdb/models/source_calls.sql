{{ config(materialized='table') }}
{#- Synthetic pre-embedded source B (sales calls). Different column names than tickets, and no
    resolvable link back to the source system — exercises knowledge_base's optional citation_url key
    (omitted here; see kb.sql). call_time is a DATE (tickets' created_at is a TIMESTAMP) ON PURPOSE:
    heterogeneous timestamp types across sources exercise knowledge_base's ts cast (finding #8) — a
    strict engine rejects the UNION without it. -#}
select 'c1' as call_id, 'acme' as account_id, 'renewal discussion' as transcript, [0.8, 0.2, 0.0]::float[3] as embedding, date '2026-01-03' as call_time
union all
select 'c2',            'acme',               'onboarding',                        [0.0, 0.0, 1.0]::float[3],       date '2026-01-04'
