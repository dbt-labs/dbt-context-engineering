{{ config(materialized='table') }}
{#- Read the three typed fields back through field with an explicit as_type, per engine. -#}
select
    {{ dbt_context_engineering.field('result', 'count', dbt.type_int()) }}      as count_val,
    {{ dbt_context_engineering.field('result', 'ratio', dbt.type_float()) }}    as ratio_val,
    {{ dbt_context_engineering.field('result', 'flag', dbt.type_boolean()) }}   as flag_val
from {{ ref('typed_generate') }}
