# 25. embedding_logic_hash as a CI-verified content hash, not a version string or an env var

## Status

Accepted, 2026-08-13.

Amended 2026-08-13: renamed `package_identity()` to `embedding_logic_hash()` before this branch
merged. The mechanism and decision are unchanged; only the identifier changed, because
"package_identity" read as covering this package's whole identity when the hash is scoped
specifically to `embed()`'s call-graph closure. A future change to, say, `chunk()`'s logic would
not move this hash at all, and the name now says so.

Amended 2026-08-14: the "audit-only, gates nothing" decision below is correct *for a hash of
source bytes*, and is unchanged. But it should not be read as "code identity has no place in the
fingerprint" — only that *this* signal doesn't. The reason the source hash can't gate anything is
that it hashes the wrong thing: comments and renames move it, so its false-positive rate forces the
retreat to audit-only, and the detection gap this record documents (a genuinely vector-affecting
change is recorded, not caught) reopens.

The direction of travel is to hash the function's BEHAVIOR, not its source, and promote THAT into
`embedding_fn_fingerprint` (ADR-0023) as a real input:

- In this repo's CI, embed a small frozen probe set per engine and hash the returned vectors,
  rounded to a float tolerance. This hash moves when — and only when — `embed()`'s output moves
  for a fixed input. The Databricks `ARRAY<DOUBLE>` → `ARRAY<FLOAT>` cast that motivates this
  record moves the probe vectors and is caught; a comment or rename leaves them identical and
  correctly triggers nothing. Its ~zero false-positive rate is what lets it gate, where the source
  hash can't. It ships through the same generated-literal + CI-verification mechanism this record
  already builds; only the hashed input changes (observed vectors, not source bytes).
- The source-bytes `embedding_logic_hash()` stays, re-scoped as a pre-merge tripwire: it still
  forces a human to look whenever `embed()`'s closure changes at all (high recall), and the
  behavioral hash decides whether that change actually reprocesses anything (high precision). Two
  signals, two jobs.
- Neither CI hash sees provider-side alias drift at consumer runtime (a floating model alias
  silently re-resolving to a new snapshot). That is only observable where and when the alias
  resolves, so it needs a runtime canary embed + test in the pipeline itself, not a compile-time
  literal. Tracked separately.

The "why not a git SHA / package version / container digest" analysis lives in the methodology
note's "Code identity in the fingerprint" addendum: the package's own resolved SHA in
`package-lock.yml` is not reachable from dbt's Jinja sandbox (no file I/O), and `DBT_CLOUD_GIT_SHA`
is the consumer project's PR commit — the wrong repository, and absent on scheduled production
runs. Source identity was never the right proxy; behavior is the thing itself.

This amendment records direction, not a shipped mechanism; the decision below stands until the
behavioral hash lands.

## Concept

Code identity answers a question `content_hash` and `embedding_fn_fingerprint` (ADR-0023)
structurally cannot: not "did the text change" or "did the configured function change," but "did
*this package's own logic* for turning text into a vector change." `embed.sql` has already lived
through this once, a cast from `ARRAY<DOUBLE>` to `ARRAY<FLOAT>` on the Databricks path changed the
vector's actual values with the model name and the input text both untouched. `embedding_logic_hash`
exists to make that kind of change auditable, without asking every embedding model in every
consuming project to reprocess every time this package ships an unrelated fix.

## Context

Two candidate mechanisms were tried and rejected before landing on this one.

`dbt_project.yml`'s `version` field is manually bumped, and, as observed directly, often isn't,
exactly the "recorded from intent, not observation" failure ADR-0023 exists to close everywhere
else. Using it here would reintroduce the same failure mode this whole feature is meant to
eliminate.

An `env_var()`-sourced git SHA looked more promising: `dbt`'s own git-package resolver already
overwrites a pinned `revision` with the real resolved commit SHA in `package-lock.yml` on every
`dbt deps`, regardless of whether a consumer pins a branch, a tag, or nothing at all (confirmed by
reading `dbt/deps/git.py` directly, not assumed). But getting that value from `package-lock.yml`
into a warehouse column still requires some delivery mechanism, and every option puts the
maintenance burden on **every downstream consumer's CI**, not on this repo. Checked whether a
macro could read `package-lock.yml` directly instead, and confirmed it cannot: dbt's Jinja
`modules` context exposes exactly `pytz`, `datetime`, `re`, `itertools`
(`dbt/context/base.py`'s `get_context_modules()`), no file I/O, and `package-lock`/`PackageLock`
appears nowhere outside dbt's own CLI internals. A reliable value with an unreliable delivery
mechanism is not actually reliable.

## Decision

**`embedding_logic_hash()` is a generated literal macro, a content hash of `embed()`'s call-graph
closure in this package's own source, computed and verified entirely by this repo's own CI, never
by a consumer or at model-compile time.**

```sql
{% macro embedding_logic_hash() -%}
    {{ return('d5f465ef...') }}
{%- endmacro %}
```

The file set is **derived**, not hand-listed: `ci/verify_embedding_logic_hash.py` starts from
`macros/functions/embed.sql`, regex-walks `dbt_context_engineering.<name>(...)` calls to find every
macro it depends on, resolves each to its defining file, and recurses until nothing new turns up.
A second CI job, wired into `.github/workflows/ci.yml`, recomputes the hash on every change and
fails the build if it disagrees with the checked-in literal.

`embedding_logic_hash()` is an **audit column only**. It is never an input to
`embedding_fn_fingerprint` and never gates reprocessing on its own.

## Reasoning

**Why the file set is derived by walking a call graph instead of hand-listed.** The same failure
mode as `dbt_project.yml`'s version field would recur one level down: a hand-maintained list is
exactly the kind of thing someone forgets to update when `embed.sql` starts calling a new helper.
Checked first whether dbt's own manifest already tracks macro-to-macro dependencies and could be
read instead of reimplementing the walk: it doesn't. `MacroParser.parse_macro()`
(`dbt/parser/macros.py`) constructs every macro node without ever populating `depends_on`, that
field is only filled in for models/tests calling macros, never for one macro calling another. So
this regex walk isn't a shortcut around a better mechanism dbt already provides, it's the actual
mechanism, and its correctness rests on this codebase's one real convention, every macro call is
package-qualified, `dbt_context_engineering.<name>(...)`, stated in the README and true everywhere
today.

**Why this is audit-only, not a fingerprint input.** Folding it into
`embedding_fn_fingerprint` would use the coarsest signal available, this package's own release
identity, as a mechanical reprocessing trigger. Any change to this package, a README fix, an
unrelated `grounded.sql` tweak, would then force a full-corpus re-embed for every embedding model
in every consuming project on every release, a real cost with no correctness benefit, since most
releases never touch `embed()`'s actual vector-producing logic at all. Scoping the hash to
`embed()`'s own call-graph closure, rather than the whole package or a raw git SHA, keeps the
signal precise to what would actually matter if it changed, without needing to force reprocessing
to get that precision.

**Why this is a content hash of source bytes, not a semantic hash of behavior, and why that's also
why it can't gate anything.** Most edits inside the closure, a comment, a rename, a new dispatch
branch for an engine nobody's using yet, change the hash without changing any vector a consumer
has already produced. Gating reprocessing on it would treat every one of those as equivalent to
the Databricks float-cast bug this record exists to make auditable, and force a full-corpus
re-embed on every one of them. That false-positive rate is the real reason this stays an audit
column rather than a blocking check, not a lesser concern about cost alone. The cost this record
accepts in exchange: a byte-for-byte change that genuinely alters output, like that same float-cast
fix, is recorded, not caught. Nothing here fires a signal at the moment such a change ships; a
human has to already suspect a discrepancy and go compare `embedded_at` ranges against
`embedding_logic_hash` values to find it. Closing that gap needs a different mechanism, prompting
whoever ships a hash-changing PR to state whether the change was cosmetic or vector-affecting,
which is not part of this decision.

**Why the regeneration step belongs to this repo's CI, not a consumer's.** A consumer never edits
anything inside `dbt_packages/dbt_context_engineering/`, that would be overwritten on the next
`dbt deps` regardless. By the time a consumer pulls a commit, the generated literal already
reflects whatever this repo's CI verified before merge, the same way any other change to
`embed.sql` reaches a consumer, by pulling a newer ref. No consumer action beyond the pin bump +
`dbt deps` they already need to receive any package update; the CI gate is what makes "forgot to
regenerate it" a blocked merge on this repo, not a silent gap anywhere.

## Consequences

- **A real, previously-unrecorded code-change event (the Databricks float-cast fix) becomes
  auditable after the fact**, without forcing anything to reprocess when the hash changes.
- **This mechanism's limit: it only detects literal, package-qualified macro calls**
  (`dbt_context_engineering.<name>(...)`), the one convention this codebase actually uses
  everywhere today. A dynamically-constructed macro name would be invisible to the call-graph walk.
  This is a stated boundary, not an oversight, confirmed against dbt-core's own parser rather than
  assumed to be a limitation worth working around preemptively.
- **A second, related limit: the hash can't distinguish a cosmetic edit from a vector-affecting one,
  and nothing prompts a human to make that call at the moment it ships.** See Reasoning above; this
  is the tradeoff accepted in exchange for avoiding false-positive-driven mass reprocessing.
- **A stale `embedding_logic_hash()` is a blocked PR on this repo**, not a runtime surprise for a
  consumer, `ci/verify_embedding_logic_hash.py --generate` is the fix, run before pushing.
- **No new consumer-facing surface area.** Nothing about installing or upgrading this package
  changes; the literal ships as ordinary package source, exactly like every other macro.
- Related: ADR-0023 (`embedding_fn_fingerprint`, the mechanical fingerprint this record's audit
  column is deliberately excluded from).

## Glossary

- **Call-graph closure**: the full set of files reachable by following calls transitively:
  `embed.sql` calls X, X calls Y, so the closure is `{embed.sql, X, Y}`, whether or not `embed.sql`
  calls Y directly.
- **Content hash**: here, a hash of file contents (plus their paths, so a rename counts as a
  change), computed once by CI and checked into the repo as a literal, distinct from ADR-0023's
  `content_hash()`, which hashes row-level text at query time.
- **Audit column**: a column kept for human debugging and provenance, not read by any comparison
  logic that decides whether to reprocess a row.
