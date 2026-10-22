{{ config(materialized='table') }}
-- extract -> ce_text with schema injected into the prompt (best-effort JSON text); field() reads
-- fields back with json_extract_path_text. evidence is optional -> null when absent, not fabricated.
-- NOTE: column aliased `extracted`, not `raw` — `raw` is a reserved word in Redshift.
with x as (
    select
        id,
        {{ dbt_context_engineering.extract(
             'txt',
             dbt_context_engineering.prompt('rs_extract', 'v1'),
             dbt_context_engineering.schema_def('rs_extract', 'v1')
        ) }} as extracted
    from {{ ref('rs_docs') }}
)
select
    id,
    {{ dbt_context_engineering.field('extracted', 'topic') }}    as topic,
    {{ dbt_context_engineering.field('extracted', 'evidence') }} as evidence
from x
