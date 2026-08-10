{#- knowledge_base must normalize heterogeneous timestamp types across sources to one common type so
    the UNION is portable (finding #8). source_calls.call_time is a DATE, source_tickets.created_at is a
    TIMESTAMP; the cast must land both as a timestamp with the DATE at midnight. Confirms the cast
    produces the expected values (and, by building at all, that the mixed-type union succeeds). On a
    strict engine (BigQuery) the un-cast union would error outright — that manifestation is
    LIVE-VALIDATION DEFERRED; here we pin the cast's result. Returns rows only on failure. -#}
select 'call_date_not_midnight_ts' as issue
from {{ ref('kb') }}
where source_type = 'call' and source_id = 'c1'
  and ts <> cast(date '2026-01-03' as {{ dbt.type_timestamp() }})

union all
select 'ticket_ts_changed' as issue
from {{ ref('kb') }}
where source_type = 'ticket' and source_id = 't1'
  and ts <> cast(timestamp '2026-01-01 10:00' as {{ dbt.type_timestamp() }})
