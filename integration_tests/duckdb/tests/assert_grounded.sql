-- Proves the grounded machinery both PASSES grounded quotes and CATCHES hallucinated ones,
-- and that normalization (case-fold + whitespace-collapse) works. Each case declares its expected
-- outcome; the row is flagged grounded via the same public helpers grounded uses. Returns rows
-- only on failure (grounded verdict != expected, or a null verdict).
with cases as (
    select * from (values
        ('g1', 'the pipeline keeps breaking nightly', 'keeps breaking',       true),   -- grounded
        ('g2', 'the pipeline keeps breaking nightly', 'keeps working',         false),  -- hallucinated
        ('g3', 'Data Cannot Leave The Account',       'data cannot leave',     true),   -- grounded via ignore_case
        ('g4', 'no data   can   leave here',          'no data can leave',     true)    -- grounded via ws-collapse
    ) as t(id, src, ev, should_ground)
),
evaluated as (
    select
        id,
        should_ground,
        {{ dbt_context_engineering.contains(
            dbt_context_engineering.norm_text('src', true, true),
            dbt_context_engineering.norm_text('ev',  true, true)) }} as grounded
    from cases
)
select id, should_ground, grounded
from evaluated
where grounded is null or grounded <> should_ground
