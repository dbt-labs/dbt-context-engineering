# 24. Inline embedding storage, a side table considered and declined

## Status

Accepted, 2026-08-13.

## Concept

There are two honest ways to store a vector: **inline**, as a column on the entity row it
describes, or in a **side table**, keyed on `(content_hash, embedding_fn_fingerprint)`, joined back
to the entity when needed. Neither is universally correct; which one is right depends on how much
text repeats across entities. This record makes the package's existing default, inline, a
deliberate choice rather than an unexamined one, now that ADR-0023 gives the corpus a real cache
key that a side table could otherwise be built around.

## Context

Every shipped example in this package, the governed incremental AI model pattern, the duckdb
integration fixtures, stores the embedding column directly on the row it describes. That was never
written down as a decision, it's simply what the first examples did. ADR-0023 introduces a real
composite cache key, `(content_hash, embedding_fn_fingerprint)`, which is exactly the kind of key a
deduplicating side table would be built on. That makes this the right moment to decide inline vs.
side table on purpose, before any downstream consumer builds against an assumption that was never
actually stated.

A side table's case: if a corpus has meaningful text repetition, boilerplate, templated fields,
identical snippets, keying on the cache key deduplicates the embedding work and the storage, and
migrating from inline to a side table later requires an expensive rewrite, and likely a full
re-embed if the original inline rows don't carry enough provenance to reconstruct the key.

## Decision

**Stay inline.** The embedding column continues to live on the entity row it describes, not in a
separate table keyed on the cache key. No macro changes; `embed()`'s output is a scalar expression
either way, and nothing about ADR-0023's columns requires a different storage shape.

## Reasoning

**Why inline is the right default for this package's actual use cases.** The shipped patterns are
document and transcript embedding, chunk-level text that is, by construction, close to unique per
row, a chunk's assembled text is a specific window of a specific document or call. Side tables earn
their complexity when the same text recurs across many entities; that's not the shape of the
primary use case this package ships for.

**Why this is worth an ADR instead of staying implicit.** Migrating later is expensive and lossy
in a specific way: it requires an expensive rewrite, and reconstructing the key from
already-embedded rows that never carried `content_hash`/`embedding_fn_fingerprint` may not be
possible without re-embedding the whole corpus. Deciding on purpose now, with the reasoning
written down, means a future maintainer choosing to add a side table is making a considered
change against a stated default, not discovering an accidental one.

**Why not build both.** A side table is real engineering surface, a dedup join, a lifecycle for
orphaned cache entries nobody references anymore, a different `vector_search` composition. Building
it speculatively, with no shipped use case that needs deduplication yet, is exactly the premature
abstraction this package's own design principle argues against elsewhere.

## Consequences

- **Simpler queries, no join required** to get from an entity to its embedding, matching every
  existing example in the README and integration tests.
- **No deduplication** across entities with repeated text; a corpus with heavy boilerplate pays for
  the same vector multiple times, in both compute and storage.
- **A future side-table adoption is a real migration, not a config flip**, and should budget for
  that cost explicitly rather than assume it's cheap, per the Context above.
- Related: ADR-0023 (the cache key this record declines to build a side table around).

## Glossary

- **Side table**: a table keyed on a value shared across many entities (here, the embedding cache
  key), joined back to the entities that reference it, rather than storing that value redundantly
  on every entity row.
- **Deduplication**: storing one copy of a repeated value (here, an embedding for identical text)
  instead of one copy per row that happens to share it.
