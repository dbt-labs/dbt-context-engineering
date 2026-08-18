# integration_tests / cloud

Runnable dbt project targeting Snowflake (`--target snowflake`), Databricks (`--target databricks`),
and BigQuery (`--target bigquery`). The cloud AI calls (`generate`, `classify`, `extract`, `embed`,
`vector_search`) have executed successfully here against mock sample data on all three
warehouses; not yet validated against real production data at scale.
