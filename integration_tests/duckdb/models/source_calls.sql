{{ config(materialized='table') }}
{#- Synthetic pre-embedded source B (sales calls). Different column names than tickets. -#}
select 'c1' as call_id, 'acme' as account_id, 'renewal discussion' as transcript, [0.8, 0.2, 0.0]::float[3] as embedding, timestamp '2026-01-03 09:00' as call_time
union all
select 'c2',            'acme',               'onboarding',                        [0.0, 0.0, 1.0]::float[3],       timestamp '2026-01-04 14:00'
