# 32. Raising the dbt version floor, declaring Fusion support, and scoping prompt/schema resolution to the calling project

## Status

Accepted, 2026-09-10. Partially supersedes [ADR-0001](0001-prompts-and-schemas-as-versioned-macros.md):
the `prompt`/`schema_def` resolver's cross-package fallback is removed. Everything else in ADR-0001
still stands.

## Concept

A `require-dbt-version` range is a **promise to installers**, not a formality: it says "this
package is validated to run on these engines." Too narrow, and it blocks a supported user for no
reason. Too wide, and it lets an unsupported user hit a real failure with no warning. The range
should track what has actually been validated, on engines actually still supported, nothing more
and nothing less.

## Context

The prior range, `[">=1.6.0", "<2.0.0"]`, was set when the package was created and never revisited.
Two things have since made it inaccurate:

**The floor was already wrong for syntax reasons.** Generic tests in this package (for example
`models/audit/ai_run_log.yml`, and every integration test project) use the `arguments:` key to
nest a test's arguments under its config. That key is only available in dbt-core 1.10.5 and later;
older versions require the pre-1.10.5 flat-argument form. `>=1.6.0` stopped being true the moment
that syntax was adopted.

**The floor was also wrong for support-lifecycle reasons.** dbt Labs supports each dbt-core minor
version for one year from its release, then it moves to critical support (security/installation
fixes only) for the rest of that year, then end of life. As of this decision, only 1.12 (active
support) and 1.11 (critical support) are unexpired; 1.10 and every earlier minor are deprecated. A
floor below the oldest still-supported minor invites a contributor to develop and test against a
version dbt Labs itself no longer patches.

**The ceiling excluded an engine we had not actually evaluated.** dbt Fusion (`dbt-fusion`, the
`dbtf` CLI) is dbt v2, a separate Rust engine, not a dbt-core minor bump. `<2.0.0` excluded it
entirely, by default rather than by a validated decision.

We validated Fusion directly against every engine/adapter combination this package targets:

- **duckdb** (credential-free tier): full `dbtf build`, 189 of 191 nodes succeed. The two
  non-successes are one seed load failure and its one dependent test, both traced to a single
  external cause (below), not to this package's code.
- **Snowflake, Databricks, BigQuery**: full `dbtf build --full-refresh --vars
  '{ai_functions_enabled: true}'`, real `embed()`/`classify()` calls fired against each warehouse,
  134 of 134 nodes succeed on every adapter.
- The same suites also pass in full on dbt-core, both on the latest release (1.12: 191/191 duckdb,
  134/134 on each cloud adapter) and on **1.11.0 itself, the exact new floor** (same result: 191/191
  duckdb, 134/134 on each cloud adapter), so the floor is validated directly, not inferred from a
  later patch.

The one duckdb exception: dbt Fusion's duckdb adapter fails to load a seed owned by an installed
package, doubling the package's path segment
(`.../dbt_packages/<pkg>/dbt_packages/<pkg>/seeds/<file>.csv`). Confirmed Fusion-engine-only (the
same seed loads correctly on duckdb under dbt-core, both on 1.12 and on 1.11.0 itself, and under
Fusion itself it loads fine on Snowflake, Databricks, and BigQuery, only duckdb fails) and confirmed
independent of how the package is installed
(reproduced identically via a plain git package reference, not just this repo's own
self-referencing local-package integration tests). It only affects this package's own
`embedding_canary_baseline` seed, which ships disabled by default. Tracked upstream as
dbt-core#16128, filed here as
[dbt-context-engineering#18](https://github.com/dbt-labs/dbt-context-engineering/issues/18).

Separately, validating Fusion also surfaced a real problem with [ADR-0001](0001-prompts-and-schemas-as-versioned-macros.md)'s
resolver design. ADR-0001's `prompt(name, version)`/`schema_def(name, version)` were built to look
a macro up in the calling project first, then fall back to this package's own namespace, so a
package could in principle ship a prompt/schema of its own. Confirmed by direct testing: that
fallback does not work on Fusion, because a package cannot resolve its own namespace from within a
macro defined in that same package. A project-local prompt resolves fine on both engines; only the
package-shipped fallback fails. Independent of Fusion, the fallback was never a sound pattern for
this package to begin with: a prompt's taxonomy is inherently tied to one consumer's business,
unlike this package's other macros. The only place in this repository that ever exercised the
fallback was this package's own illustrative example, since relocated to each integration test
project's local macros. Both facts together, not just the Fusion bug alone, are why this decision
removes the fallback rather than carrying it forward as a documented limitation.

## Decision

**We will require `[">=1.11.0", "<3.0.0"]`, replacing `[">=1.6.0", "<2.0.0"]`: the floor moves to
the oldest dbt-core minor dbt Labs still supports, and the ceiling widens to include dbt Fusion
(v2.x).**

```yaml
# dbt_project.yml
require-dbt-version: [">=1.11.0", "<3.0.0"]
```

**We will also remove the cross-package fallback from `prompt()`/`schema_def()`: a
`prompt__<name>__<version>()` or `schema__<name>__<version>()` macro must live in the calling
project, never in this package.** `macros/prompts/prompt.sql` and `schema_def.sql` no longer
attempt `dbt_context_engineering[fq]`; an unresolved name now fails immediately with "Define a
macro `<fq>()` on a macro path in your project."

## Reasoning

**Why 1.11 and not the technical minimum of 1.10.5.** 1.10.5 is the earliest version whose syntax
this package's code actually needs. But 1.10 itself is already deprecated under dbt Labs' own
support policy at the time of this decision. Declaring a floor dbt Labs no longer patches would
tell a contributor "this is fine to run" about a version that is not fine to run in production.
1.11 is the oldest minor still receiving any patches, so it is the oldest floor defensible on both
grounds at once.

**Why widen the ceiling to include Fusion rather than leave it excluded.** A `<2.0.0` ceiling that
was set by default, before Fusion was evaluated, is not a decision, it is an accident that happens
to look like one. Once validated end to end, on every adapter this package targets, with real
AI-function calls, leaving the ceiling at `<2.0.0` would misstate what has actually been confirmed
to work.

**Why declare support with one known exception still open, rather than wait for it to close.** The
exception is external (an upstream Fusion engine bug, not this package's code), narrow (one
disabled-by-default seed, on one adapter), and already tracked with a public issue on both sides.
Gating the declaration for every adapter behind a single non-default code path, on the one adapter
that has no live-warehouse cost, would understate the real, validated state of the other three
adapters and of duckdb's default (undisabled) path.

**Why remove the cross-package fallback instead of documenting it as a known Fusion limitation.**
The other exceptions in this decision (the seed-load bug) are genuine capabilities this package still offers that happen to be
broken by an external engine bug. The prompt/schema fallback is different: a prompt's taxonomy cannot be generic across
consumers the way this package's other macros are.

## Consequences

- **The floor rules out unsupported dbt-core versions by design.** A contributor can no longer
  develop or test against a minor dbt Labs has already deprecated.
- **The ceiling now covers Fusion**, so installers can adopt this package under Fusion with a
  version range that reflects real, validated behavior, not an unevaluated default.
- **One known, filed exception remains on duckdb under Fusion** (dbt-core#16128 /
  dbt-context-engineering#18): the `embedding_canary_baseline` seed, disabled by default, fails to
  load. Resolves automatically once Fusion ships a fix; no project-side workaround exists.
- **A package can no longer ship its own prompt/schema.** `prompt()`/`schema_def()` only search the
  calling project's macros now; `macros/prompts/prompt.sql` and `schema_def.sql` no longer contain
  the `dbt_context_engineering[fq]` fallback. This partially supersedes
  [ADR-0001](0001-prompts-and-schemas-as-versioned-macros.md), whose status now points here. The
  only place in this repo that used the removed path was this package's own illustrative example,
  already relocated to each integration test project's local macros.
- **CI now enforces both bounds this decision makes.** `.github/workflows/ci.yml`'s pre-existing
  `structure` and `deterministic-tests` jobs install dbt unpinned, so on their own they only ever
  validate latest, never the declared `>=1.11.0` floor, and never exercise Fusion at all. Two new
  job pairs close both gaps: `floor-structure` / `floor-deterministic-tests` pin exactly
  `dbt-core==1.11.0`, and `fusion-structure` / `fusion-deterministic-tests` run the same suites on
  dbt Fusion (installed via `pip install --pre dbt`), excluding `embedding_canary_baseline` per the
  known issue above. A future syntax change that breaks the floor, or a Fusion regression, now fails
  a PR instead of going unnoticed.

## Alternatives considered

- **Keep `<2.0.0` and treat Fusion as explicitly unsupported** until the `prompt`/`schema_def`
  cross-package fallback resolves cleanly on Fusion. Rejected: gating every adapter's declared
  support behind fixing it would understate what is actually validated and working.
- **Document the fallback as a known Fusion limitation instead of removing it.** Rejected: unlike
  the seed-load bug, the fallback was not a real capability broken by an external bug.

## Glossary

- **`require-dbt-version`**: the `dbt_project.yml` key constraining which dbt-core/dbt versions may
  build this project; installing outside the range raises a compiler error before any model runs.
- **Active support / critical support / end of life (EOL)**: dbt Labs' one-year support lifecycle
  per dbt-core minor version. Active support (bug/security fixes) for several months after release,
  then critical support (security/installation fixes only) for the remainder of the year, then EOL
  (no further patches).
- **dbt Fusion**: dbt's v2 engine, a separate Rust-based implementation from dbt-core (v1), with its
  own Jinja engine and macro resolution behavior. The binary is invoked as `dbtf` when installed via
  the curl script (local development) or as `dbt` when installed via `pip install --pre dbt` (CI);
  both run the same engine.
- **Package-shipped vs. project-local (prompt/schema)**: whether a `prompt__<name>__<version>()` /
  `schema__<name>__<version>()` macro is defined inside this installed package versus inside the
  consuming project's own macros. ADR-0001 allowed both; this decision permits only the latter.
