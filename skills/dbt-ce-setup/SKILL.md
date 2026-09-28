---
name: dbt-ce-setup
description: "Install and configure the dbt_context_engineering package in a consuming dbt project: packages.yml/dbt deps, the per-adapter var configuration everything depends on (embedding_model, model_generate/classify/extract, the ai_functions_enabled safety gate, cost ceilings, output caps), and per-engine prerequisites for Snowflake (Cortex), Databricks (serverless/DBR), and BigQuery (Vertex connection, Gemini thinking budget). Use whenever a user is setting up or configuring the package: 'how do I install dbt_context_engineering', 'which vars for Snowflake/Databricks/BigQuery', \"my AI model raises 'AI functions are disabled'\", 'why is my BigQuery bill full of thinking tokens', or 'the package cannot find my connection'. Trigger even when the user mentions only one var or one error, since the config surface is interdependent. For building the chunk/embed/search pipeline see dbt-ce-pipeline; for the AI functions and prompts see dbt-ce-ai-functions."
---

# Setting up dbt_context_engineering

This skill gets the package installed and configured in a **consuming** dbt project so the
pipeline and AI-function skills have what they need. Configuration is deliberately explicit:
the package's design rule is **config over abstraction**. Every divergent prerequisite is a
named `var` with a documented default, never inferred from the environment. That means setup
is mostly "set the right vars," and the failures are clear, actionable compiler errors rather
than opaque SQL.

## 1. Install

Add the package to `packages.yml` and install:

```yaml
# packages.yml
packages:
  - package: dbt-labs/dbt_context_engineering
    version: [">=0.1.0", "<0.2.0"]   # or a git/local ref while it is pre-release
```

```bash
dbt deps
```

The package requires **dbt `>=1.11.0, <3.0.0`** Two install worlds:

- **dbt-core (1.x)** needs Python plus the adapter you target:
  `pip install dbt-core dbt-snowflake` (or `dbt-databricks` / `dbt-bigquery` / `dbt-duckdb`).
- **dbt Fusion (2.x)** is a standalone binary, no Python. The package supports it (ADR-0032).

## 2. The most impotant variable: the spend gate

Every AI function (`embed`, `generate`, `classify`, `extract`, `ai_agg`) **raises a compiler
error unless `ai_functions_enabled` is `true` for the target.** It is `false` by default on
purpose. A fresh checkout or a CI run can never accidentally fire a real, billed AI call.

If you see `"...(): AI functions are disabled by default. Set var ai_functions_enabled: true"`,
this is the fix. Turn it on **only for the targets that should spend** (typically prod, maybe a
dev target you use deliberately), not globally:

```yaml
# dbt_project.yml  (or scope per target with target-name conditionals)
vars:
  ai_functions_enabled: true
```

## 3. Choose your models

Model choice is always explicit and always logged as it is the single largest driver of cost
and quality. Set the per-function model vars, and **pin the embedding model** (a corpus
embedded by one model cannot be searched by another, so treat a change as "re-embed
everything"):

```yaml
vars:
  embedding_model: null      # REQUIRED before embed/search — pin it
  model_generate: null       # for generate()
  model_classify: null       # for classify()
  model_extract: null        # for extract() (falls back to model_generate)
```

The right values are **adapter-specific**, see `references/adapter-config.md` for a working
per-engine table (models, embedding models, and the prerequisites each engine needs).

## 4. Per-adapter prerequisites (the short version)

Each warehouse needs one or two things beyond the model vars. Full detail and example values
are in `references/adapter-config.md`; the essentials:

- **Snowflake (Cortex):** native `AI_COMPLETE`/`AI_EMBED`/`AI_CLASSIFY`, so no connection object
  needed. If you enable the embedding canary, set `embedding_canary_vector_dimension` (Snowflake
  needs a literal vector dimension).
- **Databricks:** AI functions require DBR 15.4 LTS or above and are not available on Databricks SQL Classic. 
  DBR 18.2+ is RECOMMENDED, not required, and Pro is supported.
- **BigQuery:** enable the Vertex AI API. `bq_connection` is optional for interactive queries
  (End-User Credentials cover them) but needed for service-account/batch jobs; `bq_model` is for
  the legacy `ML.*` path only. Set **`bq_thinking_budget: 0`** for structured tasks, Gemini 2.5
  runs "thinking" on by default and bills it as output tokens.

## 5. Cost & audit controls

Sensible defaults ship; override as your corpus grows. See `references/vars-reference.md` for
the complete catalogue.

```yaml
vars:
  max_batch_rows: 10000          # guard_batch circuit-breaker ceiling (input rows)
  max_est_tokens: 5000000        # guard_batch ceiling (input tokens)
  max_output_tokens: null        # cross-engine response cap (also curbs Gemini output)
  cost_per_1k_tokens: null       # set to populate est_cost in the run log
  ai_run_log_relation: null      # where the append-only ai_run_log is written
  ai_sample_rows: null           # dev convenience: sample N rows (NOT a spend guard)
  allow_full_reembed: false      # opt-in for a full --full-refresh re-embed
```

## 6. Profiles

Configure a target per warehouse in `~/.dbt/profiles.yml` (or your project's `profiles.yml`).
The package ships `integration_tests/sample.profiles.yml` showing a single profile with
`snowflake` / `databricks` / `bigquery` / duckdb (`dev`) targets, copy its shape. DuckDB is
useful for local, credential-free deterministic work (chunking, delta, guard logic), but note
**`embed` has no DuckDB implementation**, real vectors need a live warehouse.

## 7. Verify the setup (no warehouse spend)

`dbt parse` renders the package's per-dialect SQL **without** opening a warehouse connection.
The fastest way to confirm install + config are coherent for an adapter:

```bash
dbt deps
dbt parse --target snowflake     # repeat per adapter you use
```

A clean parse means dispatch resolves and your vars are structurally valid. The `ai_run_log`
audit table is bootstrapped automatically by an on-run-start hook, you don't create it.

## Gotchas

- **"AI functions are disabled by default"** → set `ai_functions_enabled: true` (§2).
- **`generate/classify/extract: set var model_* or pass model=`** → set the per-function model
  var (§3) or pass `model=` at the call site.
- **Search returns nonsense after you changed the embedding model** → the pinning invariant;
  query and corpus must share `embedding_model`. Plan a full re-embed on any change.
- **BigQuery bill full of "thinking" tokens** → set `bq_thinking_budget: 0` for structured tasks.
- **Databricks AI function errors on a classic/Pro warehouse** → move to serverless (DBR 18.2+).

## Reference files

- `references/adapter-config.md` — per-adapter working config: example model + embedding-model
  values, the prerequisites each engine needs, and the adapter-specific vars.
- `references/vars-reference.md` — the complete `var` catalogue with defaults and what each
  controls (chunking, guards, output caps, canary, logging).
