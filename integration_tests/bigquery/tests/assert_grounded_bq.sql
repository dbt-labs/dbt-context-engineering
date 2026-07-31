-- DETERMINISTIC validation of ce_contains + ce_norm_text + ce_collapse_ws EXECUTION on this
-- warehouse (both grounded and hallucinated directions, plus ignore_case + whitespace-collapse).
-- Portable inline fixture (union all, not VALUES, for BigQuery). Fail rows only.
with cases as (
    select 'g1' as id, 'the pipeline keeps breaking nightly' as src, 'keeps breaking'    as ev, true  as should_ground
    union all select 'g2', 'the pipeline keeps breaking nightly', 'keeps working',     false
    union all select 'g3', 'Data Cannot Leave The Account',       'data cannot leave',  true
    union all select 'g4', 'no data   can   leave here',          'no data can leave',  true
),
evaluated as (
    select
        id,
        should_ground,
        {{ dbt_context_engineering.ce_contains(
            dbt_context_engineering.ce_norm_text('src', true, true),
            dbt_context_engineering.ce_norm_text('ev',  true, true)) }} as grounded
    from cases
)
select id, should_ground, grounded
from evaluated
where grounded is null or grounded <> should_ground
