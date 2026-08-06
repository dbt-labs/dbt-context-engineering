# 5. Retrieval: brute-force default, managed index opt-in

## Status

Accepted, 2026-07-30.

## Concept

**Retrieval** is the read side of context engineering: given a query, find the most relevant chunks. With embeddings, "relevant" means "closest vector," and the standard measure is **cosine similarity,** the cosine of the angle between two vectors, `1.0` for identical direction down to`-1.0` for opposite. Ranking by cosine similarity and taking the top *k* (a set number of top, similar records) is semantic search.

Concretely, semantic search is three steps: **embed the query** into the *same* vector space as the
corpus; **score** every stored chunk by its cosine similarity to that query vector; **return** the
highest-scoring `top_k`. Because query and chunks are all vectors in one space, "what is this about?" becomes a geometry question, nearness in the vector space, instead of a keyword match. That's why a search for "renewal risk" can surface a chunk that says "the customer is worried about resigning" though the two share no words. (It also means the query must be embedded by the *same* model as the corpus, see [ADR-0004](0004-version-aware-incremental-refresh.md).)

There are two ways to compute that ranking:

1. **Brute force** — compute the similarity of the query against *every* row and sort. It's `O(n)`
  per query, needs no special structure, and is exact. For thousands or low-millions of rows in a
   warehouse, it's completely fine.
2. **A vector index / search service** — a specialized structure (HNSW/IVF, or a managed service
  like Cortex Search) that answers approximate-nearest-neighbor queries in sub-linear time. It's  what you need at large scale, but it's a **stateful, separately-billed, long-lived service** with idle cost and its own lifecycle.

The design principle: the *common path* should need zero infrastructure, and the *scale path* should be a deliberate, visible opt-in. dbt manages tables, not long-running services, so an index is never something a routine `dbt run` quietly stands up.

## Context

Users must get useful retrieval out of the box without provisioning anything, yet the package must
also have an answer for scale. Those pull in opposite directions if you pick only one.

## Decision

- `vector_search` **defaults to brute-force cosine similarity over an embedding *column***, with no index required. The embedding is an ordinary column produced by `embed`, so it inherits the
table's governance, tests, and lineage. Most engines expose a scalar similarity
(`vector_cosine_similarity`); BigQuery diverges to a `VECTOR_SEARCH` table function with
`use_brute_force`, hidden behind the same macro.
- `create_vector_index` **builds a managed index, but it is opt-in,** `dbt run-operation` **ONLY, never a model.** It logs the idle-serving-cost warning, and on Databricks (whose index is created
via API/SDK, not SQL DDL) it raises with guidance rather than emitting fake SQL.

```sql
{{ dbt_context_engineering.vector_search(
     relation=ref('doc_embeddings'), embedding_column='embedding',
     query_embedding=dbt_context_engineering.embed('renewal risk'),
     top_k=5, id_column='doc_id') }}
-- → doc_id, score (cosine), ranked desc, top 5 — over a plain table, no index
```

## Reasoning

**Why brute force is the right *default*.** Start from what the first user actually needs. Their
first retrieval doesn't need sub-linear latency; it needs to *work* on the table they already have, with nothing new to provision, learn, or pay for. Brute-force cosine over an embedding column gives exactly that — it's exact (not approximate), it's plain SQL, and the embedding is an ordinary column that inherits the table's tests, lineage, and governance. And the performance objection mostly evaporates on inspection: a linear scan over thousands to low-millions of rows, which is most real corpora, is completely fine. You reach for an index at a scale many projects never hit.

**Why the index is opt-in specifically because of its *nature*, not just its speed.** The tempting
framing is "index = advanced feature, hide it behind a flag." The sharper reasoning is about *what kind of thing* an index is. A table is inert: it costs storage and nothing more when idle. A vector index or search service is a long-lived, separately-billed service with idle-serving cost and its own lifecycle. It charges to stay available even when no one queries it. That is a categorically different commitment, and it collides with a boundary principle: dbt manages tables, not services. If a routine `dbt run` could quietly stand one up, users would accumulate billing-while-idle infrastructure they never chose to create. So the reasoning wasn't "advanced, hide it" but "creating a stateful, billed service must be a deliberate, visible act" which is why it's a `run-operation.`

**The through-line.** The default should be cheap, exact, and fully inside the governed DAG;
optimizations that change the *cost-and-lifecycle model* should be opt-in and impossible to trigger
by accident. Keeping embeddings as a plain column (rather than locked inside a service) is what lets
retrieval stay governed for as long as possible before a user chooses otherwise.

## Consequences

- The common path works on a plain table with **zero external objects**, it is cheap, portable, and fully governed by dbt.
- Scaling to a managed index is a deliberate choice the user opts into via `run-operation` and must
tear down themselves; nothing bills silently after a normal build.
- Brute-force ranking is validated deterministically (a known query returns the known-closest rows in
order); `create_vector_index` is never exercised by tests because it creates billed objects.
- The `filter` argument (e.g. `filter="account_key = 'acme'"`) restricts the candidate set before
ranking — the mechanism the knowledge base uses for per-account scoping
([ADR-0006](0006-knowledge-base-union-to-common-shape.md)).

## Alternatives considered

- **Index-by-default.** Better tail latency at scale, but forces every user to provision and pay for a service, and creates long-lived infrastructure. Rejected as the default; kept as the opt-in.

## Glossary

- **Retrieval** — the read side of context engineering: given a query, find the most relevant
chunks to hand to a model or agent.
- **Embedding / vector** — a list of numbers representing the meaning of a piece of text; similar
meanings produce nearby vectors. "Embedding a query" turns the search text into the same kind of
vector as the corpus.
- **Cosine similarity** — a number from `1.0` to `-1.0` for how *aligned* two vectors are: the cosine
of the angle between them (`1.0` = same direction / most similar, `0` = unrelated, `-1.0` =
opposite). It measures *direction*, not length, which is what you want for meaning, since "great" and "fantastic" point the same way regardless of magnitude. Ranking a corpus by cosine similarity to a query vector is the mechanical heart of semantic search.
- **Brute force** — comparing the query against *every* row and sorting. Exact and needs no special
structure; linear in corpus size, which is fine up to millions of rows.
- **Approximate nearest neighbor (ANN)** — algorithms/indexes (HNSW, IVF, …) that find *almost* the
closest vectors much faster than brute force, trading a little accuracy for speed at large scale.
- **Vector index / search service** — a persistent structure or managed service implementing ANN
(e.g. Cortex Search). Fast, but a long-lived, separately-billed object with **idle-serving cost**
(it charges to stay available even when unused).
- `**top_k`** — how many best matches to return (e.g. the top 5).
- **Semantic search** — finding text by *meaning* rather than exact words: embed the query, then rank the corpus by vector similarity. It's what lets a query match a paraphrase (or another language) that shares no keywords. this is the whole payoff of representing text as embeddings.
- `**run-operation`** — a dbt command that runs a macro as a one-off action (not part of building
models); used here to create an index deliberately, outside a normal `dbt run`.

