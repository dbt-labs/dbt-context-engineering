-- LIVE: extract's flattened `signal` must be in the taxonomy. Validates field against this
-- engine's extract output shape (a null signal means the field path is wrong for the shape) and
-- that extraction stayed on-schema. Fail rows only.
{{ dbt_context_engineering.conforms_to_schema(
    ref('extract_flat_bq'), 'signal', 'EXAMPLE_signal_classify', 'v3') }}
