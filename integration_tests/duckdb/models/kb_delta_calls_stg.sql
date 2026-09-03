{{ config(materialized='view') }}
{#- Fixed control fixture, paired with kb_delta_tickets_stg. Never edited: proves a whole
    untouched source arm is skipped, not just individual untouched rows within a touched one. -#}
select 'c1' as call_id, 'acme' as account_id, 'renewal discussion' as transcript,
       [0.8, 0.2, 0.0]::float[3] as embedding, date '2026-01-03' as call_time
