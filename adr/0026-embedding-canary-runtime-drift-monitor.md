# 26. `embedding_canary`: a runtime drift monitor, complementing `embedding_logic_hash`

## Status

Accepted, 2026-08-16.

## Concept

ADR-0025's `embedding_logic_hash`, checked once by this repo's own CI before a commit ever
merges, answers "did *this package's own code* for turning text into a vector change?" It
cannot answer a different question: "did *the provider*, at the other end of `embed()`, start
returning something different, weeks after this package last shipped?" A warehouse-side model
alias can re-resolve to a new snapshot with this package's code, the configured model name, and
the input text all completely unchanged, invisible to a hash computed over source bytes that
never see a live warehouse at all.

A **canary** closes that gap the same way a canary always has: something small, cheap, and
disposable, sent into the environment you can't directly observe, whose distress is the signal.
Here, the canary is a handful of frozen, never-changing strings, re-embedded on every build and
compared, by **cosine similarity**, against a **blessed baseline**, a vector a human has already
reviewed and accepted as correct. Silence means nothing changed enough to matter. A drop in
similarity means something did, at the exact moment it happened, not whenever a human next
thinks to go check.

## Context

ADR-0025's own Reasoning section names this exact gap and explicitly puts it out of its own
scope: *"Nothing here fires a signal at the moment such a change ships; a human has to already
suspect a discrepancy... Closing that gap needs a different mechanism... which is not part of
this decision."* This record is that different mechanism. It does not revise or supersede
ADR-0025. `embedding_logic_hash`'s Concept, Decision, and Consequences all remain exactly as
true after this record as before it; nothing here corrects it. The two are complementary,
addressing two different named risks (package-code drift vs. provider drift) with two
structurally different mechanisms (CI-time source hash vs. runtime warehouse observation).

This package supports exactly three real embedding-capable engines, Snowflake, Databricks, and
BigQuery (README, `embed.sql`). duckdb has no `embed()` implementation and never will reach
parity there, since it has no AI functions at all; it is a credential-free deterministic
*testing* tier (`ADR-0015`). That fact rules out chasing runtime parity on duckdb below;
`embedding_canary` uses a fixed stand-in vector there instead.

**Live measurement found that "identical" is the wrong bar.** The same probe, re-embedded across
separate connections (not batched into one query, which only ever exercises one connection),
lands on a small number of exact, repeating vectors, not one fixed value: 2 distinct vectors
across 8 Snowflake calls, 3 across 10 Databricks calls, differing by up to 0.005 on a single
element (cosine similarity 0.999999-0.9999994 between them). BigQuery showed zero variation in
every trial. This looks like routing across a small pool of serving replicas, each internally
deterministic but numerically slightly different, not per-call randomness. An exact-match or
rounded-hash comparison, the first two designs considered here (see Alternatives), can only
answer "how much raw numeric difference is acceptable," a question with no principled answer:
any threshold picked to absorb this observed noise is calibrated against noise alone, with no
example of real drift to calibrate against, and a rounding tolerance cannot tell apart "known
benign noise" from "real drift of similar magnitude" by magnitude alone.

## Decision

**`embedding_canary` (`models/monitoring/embedding_canary.sql`) embeds four frozen probe strings
every build and keeps the raw vector; `assert_embedding_canary_matches_baseline` compares it
against a committed baseline vector via `canary_cosine_similarity`, keyed by
`(probe_id, embedding_fn_fingerprint, adapter)`, and fails when similarity drops below
`embedding_canary_similarity_threshold` (default `0.999`).**

- **Cosine similarity, not an element-wise hash.** `canary_cosine_similarity`
  (`macros/embedding/canary_cosine_similarity.sql`) reuses the same functions `vector_search`
  (`macros/retrieval/vector_search.sql`, ADR-0005) already calls to rank search results: duckdb's
  `array_cosine_similarity`, Snowflake and Databricks' `vector_cosine_similarity`, and BigQuery's
  `ML.DISTANCE` (`1 - distance` = similarity). All four confirmed live against known
  identical/orthogonal vectors before use here. The threshold question stops being "how many
  decimal places of float precision is acceptable" and becomes "would this difference change a
  search result," the actual measure this package's own retrieval already uses to decide whether
  two vectors are "the same."
- **SQL only, no Python model.** Cosine similarity is a built-in whole-vector function on every
  engine; nothing here needs the per-element access that motivated a Python-vs-SQL debate in
  review (see Alternatives).
- **Baseline stored as a JSON-array string** (`seeds/embedding_canary_baseline.csv`'s
  `baseline_vector` column), parsed back into each engine's native vector type inside
  `canary_cosine_similarity`: `PARSE_JSON(...)::VECTOR(FLOAT, n)` on Snowflake (confirmed live: the
  dimension must be a literal, not a dynamic expression, so `embedding_canary_vector_dimension`
  is a required var there), `FROM_JSON(...)` cast to `ARRAY<FLOAT>` on Databricks (confirmed live:
  `vector_cosine_similarity` rejects the `ARRAY<DOUBLE>` `FROM_JSON` produces by default, the same
  cast `embed.sql` already documents for Databricks), `JSON_EXTRACT_ARRAY(...)` on BigQuery, and a
  fixed-size `::DOUBLE[n]` cast on duckdb.
- **`embedding_canary_similarity_threshold = 0.999` by default.** Comfortably below every measured
  noise score (0.999999-0.9999994) with real margin, not tuned to any observed real drift, since
  none has been observed; see Consequences for what this margin does and doesn't establish.
- **Four frozen probes.** A pangram, a short string, a long paragraph, and a unicode string,
  never edited once shipped, since editing one intentionally re-baselines it. Each gets its own
  baseline row, so an edge-case-specific drift (e.g. a tokenizer change that only touches
  non-ASCII input) is not averaged away by a single general-purpose probe.
- **`adapter` column** on every row, including duckdb. A baseline vector from one warehouse's
  model was never meant to be compared against another's, so this is part of the join key
  specifically to make cross-engine comparison structurally impossible, not just discouraged.
- **duckdb embeds a fixed stand-in literal**, the same precedent as ADR-0020's no-AI run-log
  stand-in, because `embed()` has no duckdb implementation (`default__embed` raises for any
  adapter outside snowflake/databricks/bigquery) and never will. A green duckdb canary result
  verifies the baseline/re-bless *plumbing* only; it proves nothing about provider drift, because
  there is no real provider behind the stand-in.
- **Severity is `warn` by default**, overridden to `error` in CI via the
  `embedding_canary_test_severity` var, so a benign build never fails on a mismatch that hasn't
  been triaged, but a pull request cannot merge past one that has.
- **Baseline lives in a committed CSV seed**, package source this package's maintainers author
  and control directly, not warehouse state a consumer would need to build separately.
  `macros/operations/print_embedding_canary.sql`, a run-operation, prints the current live rows
  (including the vector serialized back to a JSON-array string via `canary_vector_to_json`) for
  copying into the seed when re-blessing after an intended `embedding_fn_fingerprint` bump.
- **`monitoring: +enabled: false` by default.** Installing this package adds no automatic
  per-build cost. A consumer who wants the canary sets `monitoring: +enabled: true` in their own
  `dbt_project.yml` and adds `embedding_canary` to their own scheduled production job's command,
  not their default or dev build command (README documents this).

## Reasoning

**Why cosine similarity instead of an element-wise hash (the mechanism this replaced).** The
first design hashed each vector element, rounded to a fixed decimal count, and compared hashes
for an exact match. Building and live-testing it surfaced the discrete-replica-state noise
described in Context, which broke the premise the hash design rested on: that "the same input
produces the same vector," with any observed difference the tolerance needed to either forgive or
catch. Two fixes were considered and rejected before this one (see Alternatives): loosening the
rounding tolerance to swallow the measured noise, and blessing every observed state as a separate
valid baseline. Both keep trying to answer "how much raw numeric difference is acceptable" without
any criterion for what "acceptable" means, so neither can be defended, only tuned after the fact
to whatever was last measured. Cosine similarity sidesteps the question instead of answering it
differently: this package already has a definition of "close enough to be the same vector" for
the one thing a vector is actually for here, ranking documents in `vector_search`, and reusing it
means the threshold is grounded in "does this preserve retrieval behavior," not degrees of float
precision that mean nothing on their own.

**Why SQL only, not the Python-primary/SQL-fallback split raised in review.** SQL is the more
broadly accepted implementation approach for this package today, and it needs no runtime beyond
what every one of this package's other macros already assumes. A Python model would be this
package's first, adding real per-engine runtime prerequisites (Snowpark, cluster Python, BigQuery
DataFrames) that exist nowhere else in this codebase, to solve a problem that, once
live-validated, SQL alone could solve. Cosine similarity being a built-in whole-vector function
on all four engines removes the original motivation for considering Python entirely: the
element-wise access that Snowflake and BigQuery lack a scalar function for is no longer needed at
all. SQL also has no coverage gaps to work around: it runs unmodified on every engine and, per
the review comments that raised the Python option, on Fusion as well. Python's coverage is
narrower by comparison, preview-maturity on Snowflake, Databricks, and BigQuery, and entirely
absent on Fusion's Spark/DuckDB CLI-only tiers. That gap reinforces the SQL-only choice on its
own; it isn't what drives it.

**Why four probes instead of one.** A single frozen string, the original sketch's design, catches
a global model/alias swap cheaply, the failure mode this canary targets. But it cannot catch
drift that is specific to input shape: a tokenizer change that only mishandles unicode, or
truncation behavior that only appears past a length threshold, would embed identically for a
short pangram and never trip a one-probe canary. Four probes cost proportionally more baseline
rows to maintain, accepted because the classes of drift they catch that one probe cannot are
exactly the kind a provider is more likely to introduce quietly (a tokenizer or preprocessing
change) than a wholesale model swap, which a single probe already covers well.

**Why disabled by default, with production-job guidance, rather than always-on or silently
opt-in.** This package's own CI runs episodically, only when a pull request opens, against this
repo's own accounts. Provider drift happens on a warehouse vendor's own schedule, unrelated to
this repo's PR cadence, so CI can catch a regression in `canary_cosine_similarity`'s own SQL but
will almost never catch real provider drift, since that requires comparing two points in time and
CI does not run continuously. The only place this canary detects what it exists to detect, per
the Concept above, is a consumer's own recurring production job, run repeatedly over time against
their own pinned model. Making it always-on would charge every consumer a real, recurring
`embed()` cost on every ad-hoc dev build too, for no matching benefit, since drift does not happen
more than a handful of times a year and a dev build's timing has nothing to do with when it might
occur. Making it silently opt-in, with no guidance on where to run it, risks the same outcome as
not building it at all: a feature nobody actually wires into a schedule delivers none of its
stated value. Disabled by default, paired with documentation pointing at a scheduled production
job specifically, is the shape that both avoids unrequested cost and gives the feature a real
chance of running where it can actually catch something.

## Consequences

- **A provider-side change that reaches a live warehouse now surfaces at the next build**,
  instead of waiting for a human to already suspect a discrepancy, closing the exact gap
  ADR-0025 named and declined to solve.
- **The threshold is grounded in retrieval relevance, not an arbitrary precision count.** A
  reviewer questioning `0.999` can ask "would this magnitude of change move a search result,"
  a question with a real answer, instead of "why 6 decimals and not 4," a question with none.
- **The threshold's lower bound is still, honestly, unverified.** Live measurement established
  the noise ceiling (0.999999-0.9999994) and confirmed the *upper* bound works, a negative-control
  test with a wildly wrong baseline vector is caught, but no real drift event has ever been
  observed to confirm `0.999` sits above the noise and below anything that would actually matter.
  This is the same honest limitation the hash design had, carried forward rather than resolved,
  because no design choice here can manufacture an example of real drift to calibrate against.
- **Re-blessing after an intended `embedding_fn_fingerprint` bump is one `run-operation` and one
  committed seed diff**, not a manual warehouse query assembled from scratch each time.
- **Snowflake needs one explicit config value the other three engines don't**:
  `embedding_canary_vector_dimension`, because `VECTOR`'s dimension is part of its type and
  Snowflake requires that dimension as a literal (confirmed live). This is a smaller asymmetry
  than the query-shape divergence the earlier hash-based design required, since the comparison
  itself is now identical in shape across all four engines.
- **A green duckdb canary result must never be read as provider verification.** It exercises the
  baseline/re-bless mechanism only; the deterministic tier has no real embedding provider behind
  it to drift.
- **No new runtime dependency, and no automatic cost on install.** This package remains pure-SQL,
  and `monitoring: +enabled: false` by default means installing this package adds no automatic
  per-build spend; a consumer only pays for the canary once they explicitly enable it and wire it
  into a job.
- **The canary only delivers its stated value inside a consumer's own scheduled production job.**
  It is disabled by default for exactly that reason: this package's own CI cannot exercise the
  scenario it exists to catch, so shipping it always-on would charge every consumer a recurring
  cost on every build, including ad-hoc dev builds, with no matching benefit.
- Related: ADR-0025 (`embedding_logic_hash`, the CI-time code-identity hash this record's
  runtime provider-drift check complements), ADR-0023 (`embedding_fn_fingerprint`, reused as the
  re-bless join key), ADR-0020 (the no-AI stand-in precedent this record's duckdb branch follows),
  ADR-0005 (`vector_search`'s cosine similarity functions, reused directly here).

## Alternatives considered

- **Element-wise hash with a rounding tolerance (the original design).** Round each vector
  element to a fixed decimal count, hash the result, compare hashes for an exact match. Built,
  live-tested, and abandoned once testing surfaced discrete-replica-state noise the design had no
  principled way to handle; see Reasoning.
- **Loosening the rounding tolerance to absorb the measured noise.** A direct patch to the hash
  design once the noise was found. Rejected: any tolerance picked this way is calibrated entirely
  against noise, with no example of real drift to calibrate against, so a genuinely small drift
  event could easily fall inside whatever tolerance was set to swallow known noise, the exact
  failure mode this canary exists to prevent.
- **Bless every observed replica state as a separate valid baseline.** Considered once the noise
  turned out to be a small number of discrete states rather than continuous jitter. Rejected:
  nothing confirms that pool is small or fixed, if it isn't, this becomes open-ended reactive
  maintenance, blessing a new state every time infrastructure rotates, with no defined end state
  and no way to tell "a new legitimate replica" from "real drift" other than by re-litigating the
  same judgment call each time.
- **Python model as the primary hash path, SQL as a mandatory fallback.** Raised in review to
  avoid Snowflake/BigQuery's lack of a scalar array-map. Moot once cosine similarity removed the
  need for element-wise access at all; even setting that aside, taking on this package's first
  Python model would have added real per-engine runtime prerequisites, and SQL runs unmodified
  everywhere, including on Fusion, while Python support is preview-only on three engines and
  absent on Fusion's Spark/DuckDB CLI-only tiers.
- **A single frozen probe.** Cheaper, one baseline row per engine instead of four, but blind to
  drift specific to input length or character set. Declined in favor of the four-probe set once
  the extra baseline-row cost was weighed against the classes of drift it alone can catch.
- **Always-`error` severity.** Simpler, one severity everywhere. Declined: it would fail a live
  production build on any mismatch before that mismatch has been triaged as real drift rather
  than an environment fluke, which the `warn`-in-prod/`error`-in-CI split avoids without weakening
  the pre-merge gate.

## Glossary

- **Canary**: a small, disposable probe sent into an environment that can't be directly observed,
  whose distress (here, a similarity drop) is the signal that something changed.
- **Blessed baseline**: a vector a human has reviewed and explicitly accepted as correct,
  committed to `seeds/embedding_canary_baseline.csv`, that live results are compared against.
- **Probe**: one of the four frozen input strings `embedding_canary` re-embeds every build.
  Never edited once shipped; an edit intentionally re-baselines that probe.
- **Cosine similarity**: a measure of how close two vectors point in the same direction,
  1 = identical direction, 0 = unrelated (orthogonal). The same measure `vector_search` uses to
  rank documents, reused here as the comparison this canary is built on.
