-- LIVE: ce_classify now returns a scalar label (normalized output contract) — it must be in the
-- taxonomy. Validates the per-engine unwrap (Snowflake :labels[0] / Databricks identity /
-- BigQuery .<field>) plus on-schema classification. Fail rows only.
{{ dbt_context_engineering.ce_conforms_to_schema(
    ref('ce_signals_sf'), 'signal', 'EXAMPLE_signal_classify', 'v3') }}
