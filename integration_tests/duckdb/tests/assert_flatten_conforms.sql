-- The intended pipeline: ce_field flattens a structured AI result to a scalar label, then
-- ce_conforms_to_schema checks that scalar against the ce_schema enum. Both flattened signals
-- (pain_point, objection) are in the taxonomy, so this returns zero rows.
{{ dbt_context_engineering.ce_conforms_to_schema(
    ref('ce_flatten_test'), 'signal', 'EXAMPLE_signal_classify', 'v3') }}
