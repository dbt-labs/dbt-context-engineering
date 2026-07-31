-- LIVE: ce_extract's flattened `signal` must be in the taxonomy. Validates ce_field against this
-- engine's extract output shape (a null signal means the ce_field path is wrong for the shape) and
-- that extraction stayed on-schema. Fail rows only.
{{ dbt_context_engineering.ce_conforms_to_schema(
    ref('ce_extract_flat_dbx'), 'signal', 'EXAMPLE_signal_classify', 'v3') }}
