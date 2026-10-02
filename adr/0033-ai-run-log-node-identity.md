# 33. Record the dbt node identity in `ai_run_log`

## Status

Accepted, 2026-10-02.

## Concept

`ai_run_log` records what AI function and model ran, but not which dbt node invoked it. Add
`node_id`, the node's dbt `unique_id`, so a log row identifies the model that produced it and can
be correlated with warehouse query history carrying the same `node_id` in dbt query comments.

## Context

One dbt invocation can execute multiple nodes that call the same function with the same AI model.
For example, `nexus_chunk_embeddings` and `nexus_topic_embed` can both call `embed` with the same
embedding model. Their existing log rows share `invocation_id`, `function_name`, and `model_name`,
so those fields cannot distinguish the source node. The same ambiguity makes it difficult to join
the AI usage record to warehouse usage history, where dbt query comments identify the node by its
unique id (for example `model.psaitt_snow_sand.nexus_claim_extractions`).

`ai_run_log` is append-only and may already exist in a consumer's warehouse. Its on-run-start
bootstrap uses `CREATE TABLE IF NOT EXISTS`, which creates a missing relation but does not evolve
an existing table. An upgrade that merely adds `node_id` to new-table DDL would therefore leave
existing consumers unable to accept the updated hook inserts.

## Decision

**Add `node_id` as the final `ai_run_log` column and stamp it from the hook's `model.unique_id`.**
Both `log_ai_run` and `complete_ai_run` include it in their explicit insert column lists. When a
hook runs without model context, the macros insert a typed string `NULL` so a run-operation or
other non-node caller does not fail. Existing macro arguments remain unchanged.

The column is last, after `event`, because adding a column to an existing table appends it. Keeping
it last in `ai_run_log_columns_sql()` gives a newly created table the same order as a migrated
table. The hooks name their insert columns explicitly, so their behavior does not depend on
physical column order.

`create_ai_run_log_table()` keeps its existing `ai_functions_enabled` and `execute` guards. After
creating the relation if needed, it inspects adapter metadata through
`adapter.get_columns_in_relation`, compares names case-insensitively, and executes
`ALTER TABLE ... ADD COLUMN node_id <type_string>` only when the column is absent. Thus the
consumer's on-run-start hook migrates legacy tables before model hooks insert rows; it commits the
schema change so an enclosing hook transaction cannot roll it back. A later run is a no-op. The
`ai_run_log` model also sets `on_schema_change='append_new_columns'` so building
the model itself can add the column to an existing incremental relation.

## Consequences

- Rows from different dbt nodes can be distinguished even when invocation, AI function, and AI
  model are identical.
- Consumers can join `ai_run_log.node_id` to warehouse query history's dbt `node_id`; completion
  rows can also be matched to their started rows using `node_id` as an additional key.
- Existing tables gain a nullable string column before hook inserts when the run-start bootstrap
  is enabled. Building the model directly also requests append-only schema evolution.
- Callers outside model-hook context can still use the macros; their `node_id` is null and cannot
  identify a dbt model.
- Fresh tables and migrated tables have a consistent column order, with `node_id` last.
