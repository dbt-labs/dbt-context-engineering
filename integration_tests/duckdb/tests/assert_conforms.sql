-- conforms_to_schema against the clean golden set: every predicted_label is in the
-- EXAMPLE_signal_classify v3 enum, so this returns zero rows. Exercises the macro end to end and
-- proves the allowed set is resolved from schema (single-sourced, no hand-copied list).
{{ dbt_context_engineering.conforms_to_schema(
    ref('eval_predictions'), 'predicted_label', 'EXAMPLE_signal_classify', 'v3') }}
