# 11. Lineage and citations as a first-class invariant

## Status

Accepted.

## Concept

When an agent says "Acme is a churn risk," the only useful follow-up is "how do you know?", and the
answer has to point at the *exact source*: this ticket, that call turn, this sentence. In analytics
we call the ability to trace a value back to where it came from **lineage**; for context an AI reads
and repeats, that same trace *is* the **citation**.

The invariant this ADR establishes: **every piece of context carries, at every stage, enough
identity to trace it back to the original row it came from, and, for extracted facts, the verbatim
span that supports it.** Attribution is not a finishing touch. It's a column present from the first
transformation and never dropped, because provenance can only be *carried*, never *reconstructed
after the fact*.

Two granularities matter, and the package keeps both:

- **Row-level lineage** — *which record* this came from (a ticket id, a call id, the chunk's source
  rows). Answers *where*.
- **Span-level evidence** — the *verbatim quote* inside that record that supports an extracted claim.
  Answers *what in it* — and, unlike a bare id, it's independently checkable.

## Context

An LLM's output is only as trustworthy as its provenance: an ungrounded claim over unattributable
context is a confident answer nobody can verify — which is worse than no answer, because it *looks*
authoritative. And the pipeline is full of places to lose the thread: chunking merges rows,
enrichment summarizes, a knowledge base unions systems, retrieval reorders and truncates. Each stage
is a chance to drop identity.

## Decision

Carry lineage at **every** stage, by construction:

- **Chunking** emits `source_rows` — the array of unit ids packed into each chunk
  (see [ADR-0002](0002-chunking-as-token-bounded-unit-packing.md)).
- **Extraction** schemas require an `evidence` field, the verbatim quote supporting each fact.
- **The knowledge base** stamps `source_type` + `source_id` on every unified row
  (see [ADR-0006](0006-knowledge-base-union-to-common-shape.md)).
- **Retrieval** carries those ids into the result set, so every hit cites its system and row.

```
retrieved hit → source_type='ticket', source_id='T-42',
                evidence="we're seriously considering not renewing"
             → traceable to the exact ticket AND the exact sentence.
```

## Reasoning

**Why attribution is non-negotiable.** The output of this whole pipeline is context an agent will
quote to a human, often to justify a decision. If a claim can't be traced to its source, it can't be
trusted or corrected — and a confidently-stated, unverifiable claim is a liability, not an asset. So
traceability is a correctness requirement, not a nicety.

**Why it must be designed in at every stage, not added at the end.** Lineage is *destroyed*, not
*derived*: the moment a chunk forgets which sentences it packed, that information is gone and no
later step can recover it. The only way to have provenance at the end is to carry it through every
transform as an ordinary column. This is exactly the analytics instinct — never ship a fact table
without keys back to its source — applied to unstructured context, where the stakes are higher.

**Why both a row id and a verbatim quote.** A row id proves *where* a fact came from; it does not
prove the fact is actually *in* that row — a model can cite the right ticket and still invent the
detail. A verbatim quote proves *what in it*, and because it's literal text it can be
machine-checked: does this quote actually appear in the source? That checkability is what makes
groundedness testing possible (see [ADR-0007](0007-context-evaluation-and-groundedness.md)).
Row-level lineage tells you the source; span-level evidence lets you *verify* the claim.

The craft lesson: **provenance is a design-time property.** Decide, at the first transformation, that
every downstream artifact will carry its origin — because you cannot bolt it on later.

## Consequences

- Every retrieval result can cite the system, the row, and the supporting quote — the difference
  between an answer and a *defensible* answer.
- Groundedness testing is *possible* because the evidence span is present and literal; without this
  invariant there'd be nothing to check (see [ADR-0007](0007-context-evaluation-and-groundedness.md)).
- Chunking and the knowledge base carry ids by construction, so lineage survives merging and
  cross-source unioning.
- The cost is deliberate and small: a few extra columns and a *required* evidence field on extract
  schemas. We pay it everywhere rather than regret its absence once.

## Glossary

- **Lineage** — the ability to trace a piece of data back to the exact source row(s) it derived from.
  Here it's carried as ids on every context row.
- **Provenance** — the origin and derivation history of a piece of data; lineage is how provenance is
  recorded and followed.
- **Citation** — provenance put to use in an answer: the source an agent can point to for a claim.
  For AI-read context, good lineage *is* a ready-made citation.
- **Evidence quote (span-level lineage)** — the verbatim snippet of source text that supports an
  extracted fact. Proves *what in the source* backs the claim, and is checkable (grounded or not).
- **`source_rows`** — the array of unit ids a chunk packed; chunk-level lineage.
- **`source_type` / `source_id`** — the system name and native row id carried through the knowledge
  base and into results, so a hit cites both which system and which record.
- **Grounded** — an evidence quote that actually appears in its source (as opposed to fabricated);
  the property the groundedness test enforces.
