-- The intended pipeline: field flattens a structured AI result to a scalar label, then
-- conforms_to_schema checks that scalar against the schema enum. Both flattened signals
-- (pain_point, objection) are in the taxonomy, so this returns zero rows.
{{ dbt_context_engineering.conforms_to_schema(
    ref('flatten_test'), 'signal', 'EXAMPLE_signal_classify', 'v3') }}
