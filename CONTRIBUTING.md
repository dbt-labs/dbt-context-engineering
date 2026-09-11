# Contributing to dbt_context_engineering

Thanks for your interest in contributing. This package is deliberately
unfinished — the patterns that matter most are the ones practitioners prove on
real corpora — and we're building it in the open. Bug reports, engine parity
findings, docs fixes, new fixtures, and new capabilities are all welcome.

By participating, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## What this package is (and isn't)

A cross-platform dbt package giving practitioners a portable toolkit for
**context engineering** — modeling the data AI agents read — across
**Snowflake (Cortex), Databricks, and BigQuery**. It ships as ordinary dbt
models, macros, seeds, and tests. It is **not** an agent, an MCP server, or a
serving layer; it produces the governed context those systems consume.

The full design rationale lives in [`docs/DESIGN_SPEC.md`](docs/DESIGN_SPEC.md),
and every major decision is recorded as an ADR in [`adr/`](adr/README.md). Read
those before proposing a change to an established pattern.

## Ground rules

These are load-bearing. A PR that violates one of them will be asked to change
before review.

1. **Adapter dispatch everywhere.** Every engine-specific macro uses
   `adapter.dispatch` with per-adapter implementations (`__snowflake`,
   `__databricks`, `__bigquery`), following the dbt-utils convention. A
   dispatched macro `x` lives in `x.sql` (the dispatch call only); the real SQL
   lives in `x__snowflake.sql`, `x__databricks.sql`, and `x__bigquery.sql`.
   `generate.sql` is the canonical reference — copy its shape.
2. **Config over abstraction.** Divergent prerequisites are named `vars`, never
   inferred. Failures must be explicit and actionable, never opaque SQL errors.
3. **Prompts are code.** Prompts and schemas are versioned Jinja macros under
   `prompts/` (see ADR-0001). Versions are explicit — no implicit "latest". No
   prompt should live only in a warehouse UI.
4. **Cost is a first-class output.** Every AI model run is logged, and every AI
   call ships with a cost guard attached. No AI call ships without a guard.
5. **Ship as ordinary dbt objects.** Nothing the package creates should surprise
   a dbt user.
6. **Lineage is non-negotiable.** Every chunk/retrieval row carries its source
   ids; extraction schemas require an evidence/quote field so each fact carries
   its source text.

## Public API conventions

- Public macros/models are **unprefixed**; callers invoke them
  package-qualified: `dbt_context_engineering.<name>`.
- The schema resolver is `schema_def`, never `schema` — `schema` is a reserved
  dbt context variable.

## Development setup

You'll need dbt (`>=1.11.0, <3.0.0`) and the adapter(s) you want to work
against. Install path depends on which engine you're running:

- **dbt-core (1.x)** requires Python:
  ```bash
  pip install dbt-core dbt-snowflake dbt-databricks dbt-bigquery dbt-duckdb
  ```
- **dbt Fusion (2.x)** installs as a standalone binary — no Python required.
  See [dbt's install docs](https://docs.getdbt.com/docs/local/install-dbt) for
  the current install command.

Either way, then install the package's own dependencies:

```bash
dbt deps
```

Credential-free deterministic tests run on DuckDB — see
[`integration_tests/duckdb/`](integration_tests). Anything requiring a live
warehouse lives in the per-adapter projects under `integration_tests/`.

## Testing posture: structure-first

There are currently **no live warehouse credentials in CI**. The merge gate is
structural:

- `dbt compile` must succeed for **all three adapters** — this proves dispatch
  emits valid SQL per dialect. Run it before you open a PR.
- Deterministic tests (chunking, cost-guard, hashing, and other logic that needs
  no warehouse) run fully on DuckDB.

Anything that *requires* a live warehouse to validate (real embeddings, vector
index creation, reconciliation against system usage tables, live inference) must
still be **built**, but flag it in your PR as `LIVE-VALIDATION DEFERRED`.

**Do not fake a pass.** Do not stub a live call in a way that hides that it was
never run against a real engine.

See [`TESTING.md`](TESTING.md) for the full test map and how to run each suite.

## Making a change

1. **Open an issue first** for anything beyond a small fix, so we can align on
   approach before you invest time.
2. **Branch** off `main`.
3. **Match the surrounding code** — comment density, naming, and idiom.
4. **Add tests.** Deterministic logic gets a deterministic test. New
   engine-specific SQL must at least compile on all three adapters.
5. **Update docs.** Touch a public macro → update the README section.
   Change an established pattern → add or amend an ADR.
6. **Run the gate locally:** `dbt compile` for each adapter + the DuckDB
   deterministic tests.

## Pull requests

- Keep PRs focused; one logical change per PR.
- Describe what shipped, note CI status, and call out any `LIVE-VALIDATION
  DEFERRED` items.
- Link the issue the PR closes.
- Be ready for review against the ground rules above.

## Reporting bugs

Open an issue with the adapter and dbt version, the macro/model involved, the
compiled SQL if relevant, and a minimal reproduction. Engine parity gaps are
especially valuable — tell us which engine diverges and how.

## License

By contributing, you agree that your contributions will be licensed under the
[Apache License 2.0](LICENSE) that covers this project.
