-- Proves conforms_to_schema resolves the enum from schema and CATCHES an out-of-taxonomy
-- label while passing valid ones. Uses the same public schema_enum the macro uses. Returns
-- rows only on failure (conformance verdict != expected).
with cases as (
    select * from (values
        ('c1', 'pain_point',    true),   -- valid label
        ('c2', 'not_a_label',   false),  -- invented label -> must be caught
        ('c3', 'buying_signal', true)    -- valid label
    ) as t(id, label, should_pass)
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
