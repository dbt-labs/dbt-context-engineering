# 37. The Databricks runtime prerequisite is documented, not enforced

## Status

Accepted, 2026-11-10.

## Concept

Some prerequisites can be checked before a query runs, and some are better left to the engine. A
**pre-check** asks the warehouse a question up front and raises a friendly error if the answer is
wrong. It earns its keep when the engine's own failure is confusing and the check is accurate. It
does harm when the check is wrong, because it blocks a setup that would have worked, or when it
repeats a message the engine already gives.

Databricks documents two requirements for its AI functions: **Databricks Runtime (DBR) 15.4 LTS or
above**, and **not a Classic SQL warehouse**. The package has always carried a macro,
`require_databricks_ai_runtime()`, where a check for that would live. This record settles whether
the macro should do anything.

## Context

`require_databricks_ai_runtime()` is called from `generate`, `extract`, `classify`, `embed` and
`ai_agg` on Databricks, and its body is empty. The facts that decide whether to fill it, each
observed on a live workspace on 2026-11-10:

- **A SQL warehouse reports no DBR version.** On a SQL warehouse that runs the AI functions
  successfully, `current_version()` returns a `dbsql_version` and no `dbr_version`:

  ```
  select to_json(current_version())
  -> {"dbsql_version":"2026.45","u_build_hash":"...","r_build_hash":"..."}
  select current_version().dbr_version  -> null
  ```

  An all-purpose cluster does report it, for example `"dbr_version":"14.3.x-photon-scala2.12"`.
- **A Classic warehouse reports the same shape as a Pro warehouse.** Neither `current_version()` nor
  `version()` distinguishes them.
- **Databricks already names the Classic failure.** On a Classic warehouse:

  ```
  select ai_query('databricks-claude-haiku-4-5', 'Reply with the word ok.')
  -> [AI_FUNCTION_UNSUPPORTED_ERROR] The function `ai_query` is not supported in the current
     environment. It is only available in Databricks SQL Pro and Serverless. SQLSTATE: 56038
  ```

- **A below-floor cluster fails in the wrappers, with errors that do not name the runtime.** On a
  DBR 14.3 cluster a bare `ai_query` call succeeds, while `generate` and `extract` fail with
  `[UNRECOGNIZED_PARAMETER_NAME]` because `ai_query` has no `modelParameters` argument at that
  runtime, `classify` fails with `[AI_FUNCTION_UNSUPPORTED_ERROR]` for `ai_classify`, and
  `search` fails with `[UNRESOLVED_ROUTINE]` for `vector_cosine_similarity`.
- **The floor is not stable.** The Databricks AI Functions page links an announced change to
  "AI Functions require Databricks Runtime 17.3 LTS or above". `vector_cosine_similarity` is
  documented as DBR 18.1 and above.
- **A check has a cost.** The `current_version()` round trip took about 5 seconds on a warm
  warehouse and about 14 seconds on a cold start, and it would run for every AI-calling model.

## Decision

**We will leave `require_databricks_ai_runtime()` as an empty marker and rely on the errors
Databricks raises.** The macro stays at each call site so the prerequisite is visible where it
applies. The prerequisites are stated in the README, `TESTING.md` and the setup skill, with the
named Classic error and the cluster behavior above.

## Reasoning

**Why not check the DBR version?** A check written as `dbr_version >= 15.4` would raise on every SQL
warehouse, because the field is null there, and SQL warehouses are the recommended compute for dbt on
Databricks and the tier the package was validated on. A check that tolerates the null is a check that
does nothing on the compute most users have.

**Why not detect Classic?** No version field separates a Classic warehouse from a Pro one, so there
is nothing to test. Databricks already raises a named error for it, so a macro check would add a
round trip to say the same thing in different words.

**Why not check only when `dbr_version` is present?** It would cover all-purpose clusters, but a
hard-coded floor goes stale when Databricks moves it to 17.3, and it still costs a round trip per
model. The below-floor failures are real but they are errors from Databricks, not silent wrong
answers.

**Why not an opt-in variable?** It would add a setting for a check that could be wrong or stale,
and a failing path we could only test on a cluster below the floor.

## Consequences

- **A user on an unsupported Classic warehouse gets Databricks' own named error**, not a package
  error. It states the supported tiers.
- **A user on a cluster below the supported runtime gets a Databricks error that does not name the
  runtime.** The setup documentation is where the version requirements are stated.
- **`vector_search` and `embedding_canary` need `vector_cosine_similarity`, which is DBR 18.1 and
  above on a cluster.** On a cluster at 17.3 the AI wrappers pass and these two fail with
  `[UNRESOLVED_ROUTINE]`. SQL warehouses are not affected.
- **No per-model round trip is added**, and no version number lives in the macros to go stale.
- **The macro remains a call-site marker.** Enforcement can be added later without touching the
  call sites.

Related: [ADR-0036](0036-redshift-support-bedrock-external-models.md) records the same stance for
Redshift, where the equivalent macro `require_redshift_bedrock()` is also advisory.

## Alternatives considered

- **Check `dbr_version >= 15.4` in the macro.** Rejected. It fails SQL warehouses, where the field
  is null.
- **Check the version only when `dbr_version` is present.** Rejected. It covers only clusters, goes
  stale at the announced move to 17.3, and adds a round trip per model.
- **An opt-in variable that turns the check on.** Rejected. It adds a setting for a check that
  cannot be validated on the failing case.

## Glossary

- **DBR (Databricks Runtime):** the versioned software image an all-purpose cluster runs. A SQL
  warehouse does not report one.
- **All-purpose cluster:** Databricks compute for interactive and general workloads, addressed by an
  `http_path` of the form `sql/protocolv1/...`. A dbt profile can point at one instead of a warehouse.
- **SQL warehouse (Classic, Pro, Serverless):** Databricks SQL compute in three tiers. Databricks
  supports its AI functions on Pro and Serverless, not Classic.
- **Pre-check:** a macro that queries the warehouse before the real work and raises a friendly error
  if a prerequisite is unmet.
- **`current_version()`:** a Databricks SQL function that returns version details as a struct.
