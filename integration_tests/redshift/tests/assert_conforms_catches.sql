-- DETERMINISTIC validation of schema_enum resolution + conformance logic on this warehouse:
-- a valid label passes, an invented one is caught. Fail rows only.
with cases as (
    select 'c1' as id, 'pain_point'    as label, true  as should_pass
    union all select 'c2', 'not_a_label',   false
    union all select 'c3', 'buying_signal', true
),
evaluated as (
    select
        id,
        should_pass,
        label in (
            {%- for v in dbt_context_engineering.schema_enum(
                    dbt_context_engineering.schema_def('EXAMPLE_signal_classify', 'v3')) -%}
            '{{ v }}'{% if not loop.last %}, {% endif %}
            {%- endfor -%}
        ) as conforms
    from cases
)
select id, should_pass, conforms
from evaluated
where conforms <> should_pass
