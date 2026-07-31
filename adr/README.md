# Architecture Decision Records

The [ADRs](https://adr.github.io/) for `dbt_context_engineering` — one file per major architectural
decision, in [Michael Nygard's format](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
(Status · Context · Decision · Consequences). Each record captures the *why* behind a piece of the
package; the *what/how* is in the README's macro reference.

Each ADR opens with a plain-language **Concept** section and closes with a **Glossary** defining the
terms it uses, so a record is readable by someone brand new to context engineering — no prior
vocabulary assumed. Context engineering is a young discipline; the ADRs try to teach the idea, not
just record the choice.

## Index

| ADR | Title | Status |
|---|---|---|
| [0000](0000-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0001](0001-prompts-and-schemas-as-versioned-macros.md) | Prompts and schemas as versioned Jinja macros | Accepted |
| [0002](0002-chunking-as-token-bounded-unit-packing.md) | Chunking as token-bounded unit packing | Accepted |
| [0003](0003-cost-as-a-first-class-output.md) | Cost as a first-class output: guard + run log | Accepted |
| [0004](0004-version-aware-incremental-refresh.md) | Version-aware incremental refresh, no custom materialization | Accepted |
| [0005](0005-retrieval-brute-force-default-index-opt-in.md) | Retrieval: brute-force default, managed index opt-in | Accepted |
| [0006](0006-knowledge-base-union-to-common-shape.md) | Knowledge base: union sources into a common shape | Accepted |
| [0007](0007-context-evaluation-and-groundedness.md) | Context evaluation & groundedness as deterministic tests | Accepted |
| [0008](0008-normalizing-ai-output.md) | Normalizing AI output: scalar classify + `ce_text`/`ce_field` | Accepted |
| [0009](0009-portable-enum-enforcement-via-prompt-injection.md) | Portable enum enforcement via prompt injection | Accepted |
| [0010](0010-four-ai-operations.md) | Four AI operations: generate, classify, extract, embed | Accepted |
| [0011](0011-lineage-and-citations-as-a-first-class-invariant.md) | Lineage and citations as a first-class invariant | Accepted |
| [0012](0012-ai-as-a-row-level-sql-function.md) | AI as a row-level SQL function (prompt → column) | Accepted |
| [0013](0013-attach-metadata-as-a-separate-macro.md) | Attach source metadata as a separate, non-dispatched macro | Accepted |
| [0014](0014-generic-metadata-explicit-provenance.md) | Metadata is generic in the transform macro, provenance is explicit in the knowledge base | Accepted |
| [0015](0015-functional-test-parity-across-tiers.md) | Functional test parity across all integration tiers | Accepted |
| [0016](0016-in-text-additive-metadata.md) | `in_text` embeds metadata in addition to the columns, never instead of them | Accepted |
| [0017](0017-teardown-across-platforms.md) | Teardown works on every integration platform to support iteration | Accepted |

## New here? A reading path

Context engineering is a **pipeline**: raw text → chunk → enrich → embed → retrieve → knowledge base,
all wrapped in governance (cost, versioning, lineage, evaluation). The ADRs aren't numbered in
teaching order, so if you're starting from zero, read them in the order below — it doubles as a tour
of the discipline.

1. **How any of this works** — the mental model and the input side.
   - [0012](0012-ai-as-a-row-level-sql-function.md) — AI as a row-level SQL function (a prompt becomes a column)
   - [0001](0001-prompts-and-schemas-as-versioned-macros.md) — prompts & schemas as code (and what *structured output* is)
   - [0010](0010-four-ai-operations.md) — the four things you can ask a model to do
   - [0008](0008-normalizing-ai-output.md) — reading the AI's answer back out
2. **Preparing the text.**
   - [0002](0002-chunking-as-token-bounded-unit-packing.md) — chunking (and what an *embedding* is)
   - [0013](0013-attach-metadata-as-a-separate-macro.md) — attaching source metadata onto chunks
   - [0016](0016-in-text-additive-metadata.md) — embedding metadata into the chunk text
3. **Reading it back.**
   - [0005](0005-retrieval-brute-force-default-index-opt-in.md) — retrieval (and *cosine similarity* / *semantic search*)
   - [0006](0006-knowledge-base-union-to-common-shape.md) — unifying many sources into one knowledge base
   - [0014](0014-generic-metadata-explicit-provenance.md) — how provenance is promoted in the knowledge base
4. **Making it affordable, correct, and trustworthy** — the governance that makes it production-grade.
   - [0003](0003-cost-as-a-first-class-output.md) — cost (the token economy, guard + log)
   - [0004](0004-version-aware-incremental-refresh.md) — version-aware incremental refresh
   - [0011](0011-lineage-and-citations-as-a-first-class-invariant.md) — lineage & citations end to end
   - [0007](0007-context-evaluation-and-groundedness.md) — evaluation & groundedness
   - [0009](0009-portable-enum-enforcement-via-prompt-injection.md) — portable enum enforcement
   - [0015](0015-functional-test-parity-across-tiers.md) — functional test parity across integration tiers
   - [0017](0017-teardown-across-platforms.md) — teardown across platforms to support iteration

## Conventions

- Numbered `NNNN-kebab-title.md`; numbers are stable and never reused. `0000` is the meta-record
  that establishes this practice.
- Copy `template.md` to start a record. Each record carries Status, Concept, Context, Decision,
  Reasoning, Consequences, an optional Alternatives considered, and Glossary.
- The `## Status` line states the status and the date, for example `Accepted, 2026-07-30.`.
- A decision is never edited to say something different — supersede it with a new ADR and flip the
  old one's status to `Superseded by ADR-XXXX`. (Small factual amendments are noted inline, dated.)
