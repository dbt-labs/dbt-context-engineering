-- LIVE validation of ce_field on the REAL per-engine AI output shape (VARIANT / JSON string /
-- STRUCT): flatten ce_generate's structured result to a scalar `signal`, then assert it conforms
-- to the ce_schema enum. Catches both a broken ce_field path (null signal) and an off-taxonomy
-- generation. Fail rows only.
{{ dbt_context_engineering.ce_conforms_to_schema(
    ref('ce_flatten_dbx'), 'signal', 'EXAMPLE_signal_classify', 'v3') }}
