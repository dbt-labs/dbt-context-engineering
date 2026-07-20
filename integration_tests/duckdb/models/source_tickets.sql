{{ config(materialized='table') }}
{#- Synthetic pre-embedded source A (support tickets). -#}
select 't1' as ticket_id, 'acme'   as account_id, 'login broken'     as body, [1.0, 0.0, 0.0]::float[3] as embedding, timestamp '2026-01-01 10:00' as created_at
union all
select 't2',              'globex', 'billing question',                   [0.0, 1.0, 0.0]::float[3],       timestamp '2026-01-02 11:00'
