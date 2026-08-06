-- LIVE validation of field on the REAL per-engine AI output shape (VARIANT / JSON string /
-- STRUCT): flatten generate's structured result to a scalar `signal`, then assert it conforms
-- to the schema enum. Catches both a broken field path (null signal) and an off-taxonomy
-- generation. Fail rows only.
{{ dbt_context_engineering.conforms_to_schema(
    ref('flatten_bq'), 'signal', 'EXAMPLE_signal_classify', 'v3') }}
