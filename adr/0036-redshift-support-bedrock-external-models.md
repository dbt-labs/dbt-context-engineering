# 35. Redshift support: Bedrock inference UDFs, best-effort structured output, pure-SQL cosine

## Status

Accepted, 2026-10-22.

## Concept

Every engine this package supported before Redshift — Snowflake (Cortex), Databricks, BigQuery —
exposes AI as a **built-in, inline SQL function** (`AI_COMPLETE`, `ai_query`, `AI.GENERATE`) and a
**native vector primitive** (a `VECTOR`/`ARRAY` type with a scalar cosine). The package's whole
portability promise rests on that shared shape: one wrapper macro, a per-engine body behind
`adapter.dispatch`, and the same typed scalar coming back out.

Amazon Redshift has **neither**. Its generative-AI story is **Amazon Bedrock via Redshift ML**: you
run `CREATE EXTERNAL MODEL … MODEL_TYPE BEDROCK` once, which mints a **user-defined inference
function** that calls Bedrock per row. There is no built-in AI function, no `response_format` to
pin output shape, and no vector type or cosine — embeddings land in a `SUPER` (semi-structured)
column. Redshift is therefore the package's **architectural outlier**: supporting it is a real port,
not a twentieth dispatch shim. This record captures the decisions that port required.

## Context

The forces that make Redshift non-obvious, each confirmed live against a real Redshift + Bedrock
warehouse (2026-10-22):

- **No inline AI function.** AI runs through a UDF that must be **provisioned out-of-band** with
  `CREATE EXTERNAL MODEL` — a stateful, IAM-bound DDL step that needs `GRANT CREATE MODEL`, a role
  with `bedrock:InvokeModel`, and model access enabled in the Bedrock console.
- **No structured output.** Bedrock-via-Redshift returns **plain text**. There is no
  `response_format`/schema-enforcement knob, so `classify`/`extract`/structured `generate` cannot be
  structurally guaranteed the way the other three engines guarantee them.
- **No vector type or scalar cosine.** Embeddings are `SUPER` arrays. There is no
  `vector_cosine_similarity`, and **Python UDFs — the obvious place to put a scalar cosine — reach
  end-of-support 2026-06-30**, closing that door.
- **The SQL dialect diverges** in several load-bearing spots: no `QUALIFY`, no `ARRAY_AGG`, no
  row-constructor `IN`, no `regexp_extract_all`, no backreferences in `REGEXP_REPLACE` (but PCRE
  lookaround *is* available via the `'p'` flag), and the parser rejects path navigation applied
  directly to a function result (`f(...).field`).
- **Operational facts that bite at invocation, not creation:** in `us-east-2` on-demand requires a
  **cross-region inference profile** id (`us.*`), not the bare model id; UNIFIED inference-config
  keys are camelCase and silently ignored if wrong (`maxTokens`); and foundation models reach
  **end of life** (Claude 3.5 Sonnet v1 did), so a provisioned function can start failing later.

## Decision

**We will support Redshift as a first-class engine by dispatching every divergent macro to a
`redshift__` body, routing all AI through a consumer-provisioned Bedrock inference UDF, and
accepting that structured output and the drift canary are degraded — explicitly and loudly — rather
than faked.** Specifically:

- **Provisioning is a run-operation, never a model build.** `create_bedrock_function` (a sibling of
  `create_vector_index`) emits the `CREATE EXTERNAL MODEL` DDL; it takes `replace=true` to re-point a
  function (Redshift has no `CREATE OR REPLACE` for external models), and emits `IAM_ROLE default`
  unquoted when asked for the default role.

- **The model vars name the UDF on Redshift.** `var('model_generate')` → the text UDF (e.g.
  `ce_text`), `var('embedding_model')` → the embedding UDF (e.g. `ce_embed`). The model id lives
  inside the external-model object, so the wrapper splices the var as a function identifier, not a
  quoted model string. Wrapper signatures are unchanged.

- **Structured output is best-effort, prompt-enforced.** `redshift__generate`/`extract` inject the
  schema into the prompt (`augment_prompt` for enums + `redshift_output_instruction` for the JSON
  shape) and read the returned text back with `field()` → `json_extract_path_text`.
  `redshift__classify` instructs a bare label and `trim()`s it. The schema stays the single source
  of truth; the contract is prompt-enforced, not structural.

- **`vector_search` is a pure-SQL cosine over `SUPER` arrays** — unnest both the candidate and query
  vectors with PartiQL `… AS e AT i`, join on index, aggregate `dot/‖a‖/‖b‖` per a synthetic row
  key. `embed` extracts the vector with `json_parse(json_extract_path_text(json_serialize(f(...)),
  'embedding'))` (pure function nesting, because `f(...).embedding` is a parse error).

- **Degraded features raise with guidance, never fake output.** `create_vector_index` and the
  `embedding_canary` cosine both raise a clear "not supported on Redshift" on this engine.

## Reasoning

**Why a run-operation for provisioning, not auto-creation inside a model?** `CREATE EXTERNAL MODEL`
is stateful, IAM-bound, and billed-capable; it is a setup step with its own lifecycle, exactly like
BigQuery's connection or a Cortex Search service. A model build must stay idempotent and
side-effect-free on external infrastructure, so provisioning lives where `create_vector_index`
already put that class of action: an explicit, logged `dbt run-operation`.

**Why overload the existing vars instead of adding `redshift_*_function` vars?** The wrapper
signature and the `model=`/`var(...)` fallback chain are identical across engines; only the *meaning*
of the value differs (UDF name vs. model string). Overloading keeps one configuration surface and
one code path, with the divergence documented rather than branched. A separate var set would add
surface for no behavioral gain.

**Why accept best-effort structured output rather than refuse `classify`/`extract` on Redshift?**
The alternative to prompt-enforcement is not structural enforcement — Redshift offers none — it is
*no feature at all*. A prompt-injected enum plus a JSON-shape instruction, validated by the same
`conforms_to_schema`/assertion tests, gets real, usually-correct output (live: `classify` landed
on-enum, `extract` returned typed fields with verbatim evidence). Shipping it with a loud caveat
beats withholding a capability that works in practice.

**Why pure-SQL cosine rather than a UDF?** A scalar cosine over two arrays is not expressible inline
without unnest+aggregate, and the natural home for a scalar implementation — a Python UDF — is being
removed from Redshift (June 2026). A Lambda UDF would drag external infrastructure into what is meant
to be a brute-force, in-warehouse default. Expressing the cosine as a self-contained unnest-join
keeps `vector_search` dependency-free, matching the "brute-force default, managed index opt-in"
stance of ADR-0005. The external index path (S3 Vectors / OpenSearch) is deliberately out of scope.

**Why raise for `embedding_canary` instead of a scalar subquery?** The canary needs a *scalar*
cosine embeddable in a `SELECT`, which on Redshift would require a correlated subquery unnesting an
outer row's `SUPER` column — fragile SQL we are unwilling to ship unvalidated. The canary is an
opt-in beta monitor, so raising with guidance is honest and contained; the core retrieval path is
unaffected.

## Consequences

- **Easier:** a Redshift shop gets the whole pipeline — chunk, embed, retrieve, generate, classify,
  extract, ai_agg — behind the **same wrappers** as every other engine; nothing in a consumer's
  model SQL changes between warehouses.
- **Harder:** Redshift carries a **mandatory provisioning step** (`create_bedrock_function` + IAM +
  `GRANT CREATE MODEL` + model access) with no analogue on the other engines, and its **structured
  output is best-effort** — assertions, not the engine, are what catch off-schema drift.
- **Degraded surface, documented:** `create_vector_index` and `embedding_canary` are **unsupported
  on Redshift** (raise with guidance); `source_rows` from `chunk` is a `SUPER` array of **stringified
  ids** (the other engines keep the native type).
- **New live-validation items** recorded in the macro comments: PCRE lookbehind for sentence
  splitting, `SUPER→float8` casts, the `JSON_SERIALIZE` 64KB cap for very high-dim embeddings, and
  that `standard_conforming_strings` is assumed on (so `str_literal` maps to the ANSI default).
- **Follow-on:** `create_ai_run_log_table` gained a Redshift branch (existence-check + plain CTAS,
  because Redshift rejects `CREATE TABLE IF NOT EXISTS … AS`). Relates to ADR-0005 (retrieval),
  ADR-0009 (portable enum via prompt injection — Redshift reuses it), ADR-0012/0018 (AI as a
  row-level function / structured-generate as the extract primitive), ADR-0026 (the canary this
  disables on Redshift), and ADR-0029 (incremental chunk, whose delta predicate becomes `NOT
  EXISTS` here).

## Alternatives considered

- **Join Redshift into the existing `integration_tests/cloud` project as a 4th target.** Rejected:
  Redshift's best-effort output breaks the cloud suite's schema-conformance assertions, and it needs
  out-of-band provisioning the other three do not — a separate `integration_tests/redshift` project
  tests what Redshift actually supports, honestly.
- **A scalar cosine via Lambda UDF.** Rejected for the default path: it pulls external infra into a
  brute-force in-warehouse feature. Left open as the documented way to later restore the canary.
- **Refusing structured `classify`/`extract` on Redshift.** Rejected: prompt-enforcement works in
  practice and a withheld capability helps no one.

## Glossary

- **External model (Redshift ML):** a database object created by `CREATE EXTERNAL MODEL` that points
  at a remote model (here, an Amazon Bedrock foundation model) and mints a SQL **inference function**
  to call it. It holds no standing compute — cost is per-invocation Bedrock tokens.
- **Inference function / UDF:** the function minted by the external model; the package calls it in
  place of the other engines' built-in `AI_COMPLETE`/`ai_query`/`AI.GENERATE`.
- **UNIFIED vs RAW request type:** UNIFIED uses Bedrock's Converse API (message models, e.g. Claude)
  and takes `(text, inference_config)`; RAW takes one `SUPER` request body you build for the specific
  model (e.g. Titan embeddings) and returns a `SUPER` response.
- **Inference profile:** a Bedrock routing id (prefix `us.`/`global.`) required for on-demand
  invocation of current models in Regions where in-region on-demand isn't offered (e.g. us-east-2).
- **SUPER:** Redshift's semi-structured type (JSON-like), navigated with PartiQL dot/bracket paths;
  how this package stores embedding vectors on Redshift.
- **Best-effort (structured) output:** output whose shape is enforced by instructions in the prompt
  rather than by the engine, so correctness is validated by tests, not guaranteed by the warehouse.
