{{ config(materialized='view') }}
{#- Two-phase fixture (var kbd_phase) for knowledge_base's per-arm incremental
    mechanism. Phase 2: t2's body is edited, t3 appears for the first time, t1 is untouched. -#}
select 't1' as ticket_id, 'acme' as account_id, 'login broken' as body,
       [1.0, 0.0, 0.0]::float[3] as embedding, timestamp '2026-01-01 10:00' as created_at,
       'https://tickets.example.com/t1' as ticket_url, 'bug' as category
union all
select 't2', 'acme',
       {{ "'billing question (revised)'" if var('kbd_phase', 1) | int == 2 else "'billing question'" }},
       [0.0, 1.0, 0.0]::float[3], timestamp '2026-01-02 11:00',
       'https://tickets.example.com/t2', 'billing'
{% if var('kbd_phase', 1) | int == 2 %}
union all
select 't3', 'acme', 'new ticket', [0.5, 0.5, 0.0]::float[3], timestamp '2026-01-05 09:00',
       'https://tickets.example.com/t3', 'bug'
{% endif %}
