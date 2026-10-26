# 34. Keep the AI run log in the current target under state deferral

## Status

Accepted, 2026-10-05.

## Concept

The AI run log belongs to the target that is executing the work. State deferral may redirect model
references to another environment, but it must not redirect the run's DDL or audit rows.

## Context

The run-log bootstrap and the `log_ai_run` and `complete_ai_run` hooks use `ref('ai_run_log')`.
When state deferral is enabled and the log model is not selected, dbt can resolve that reference to
the relation recorded in the deferred manifest. If the current target has no run log yet, a CI job
that defers to production can therefore alter the production table during bootstrap and write its
own lifecycle rows there. The current target remains without its run log.

The `ref()` calls also declare DAG edges and must continue to render in all three macros. They
cannot be removed as part of changing the runtime write destination.

## Decision

**Use the `ai_run_log` graph node configured for the active target as the runtime relation.** A
shared audit macro looks up the package model in `graph.nodes` and constructs a table relation from
its configured database, schema, and alias. The bootstrap uses that relation for creation, column
inspection, and schema migration; both lifecycle hooks use it as their insert target. Each caller
continues to render `ref('ai_run_log')` for dependency inference and uses it as the fallback when
execution or graph metadata is unavailable.

## Consequences

- A deferred run creates and writes the run log in its own target while retaining the dependency on
  the package model.
- The deferred relation is not altered or populated by that invocation's run-log hooks.
- Parse-time rendering remains valid through the `ref()` fallback.
- Target ownership follows the package model's configured database, schema, and alias, including
  target-specific schema generation.
- Integrations must keep the package model enabled and configured in the consuming project's DAG so
  the graph node is available during execution.
