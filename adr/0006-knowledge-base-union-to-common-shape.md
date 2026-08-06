# 6. Knowledge base: union sources into a common shape

## Status

Accepted, 2026-07-30.

## Concept

Useful questions rarely live in one table. "Tell me everything about account *Acme*" spans support
tickets, call transcripts, meeting notes, and emails, each in its own table, with its own column
names (`ticket_id` vs `call_id`), its own grain, and its own timestamp column. An agent shouldn't
have to know that `stg_tickets.body` and `stg_calls.transcript` are "the same kind of thing."

The classic data-warehouse answer is a **conformed dimension**: define one canonical shape and map
every source into it, so a single query spans them all. A **knowledge base** here is exactly that,
a conformed, retrieval-ready mart. Every source is normalized to the same six columns:

| column | meaning |
|---|---|
| `source_type` | which system (`'ticket'`, `'call'`, …) — lineage |
| `source_id` | the row's id in that system — lineage |
| `account_key` | the grouping key you filter on (account/tenant) |
| `text` | the content |
| `embedding` | its vector |
| `ts` | when it happened |

Because everything lands in this shape, one `vector_search(..., filter="account_key = 'acme'")`
answers a cross-system question, and every hit still carries `source_type` + `source_id` so the
answer can **cite which system and row** it came from.

## Context

The sources are heterogeneous (different columns, grain, names) but the retrieval surface wants to
be homogeneous. Adding a new source (say, Slack messages) should be a small, obvious change, not a
rewrite of the retrieval query.

## Decision

**`knowledge_base(sources)`** unions many pre-embedded source relations into one mart in the
common shape. `sources` is a list of dicts, each mapping one source's columns onto the shape;
**registering a new source is adding one dict.** It is pure portable SQL — a `UNION ALL` with casts,
no per-engine dispatch.

```sql
{{ dbt_context_engineering.knowledge_base([
  {'relation': ref('stg_tickets'), 'source_type': 'ticket',
   'source_id': 'ticket_id', 'account_key': 'account_id',
   'text': 'body', 'embedding': 'embedding', 'timestamp': 'created_at'},
  {'relation': ref('stg_calls'),   'source_type': 'call',
   'source_id': 'call_id',   'account_key': 'account_id',
   'text': 'transcript', 'embedding': 'embedding', 'timestamp': 'call_time'},
]) }}
-- → one mart: source_type, source_id, account_key, text, embedding, ts
```

Then retrieval is the ordinary macro with a filter:

```sql
{{ dbt_context_engineering.vector_search(
     relation=ref('knowledge_base'), embedding_column='embedding',
     query_embedding=dbt_context_engineering.embed('renewal risk'),
     id_column='source_id', select_columns=['source_type'],
     filter="account_key = 'acme'") }}
```

## Reasoning

**Why borrow the conformed-dimension pattern.** Real questions don't respect table boundaries, so
"everything about Acme" lives in tickets, calls, notes, and emails at once. Analytics solved the
"many heterogeneous sources, one question" problem long ago with the conformed dimension: define one
canonical shape and map every source into it. Context engineering has the identical problem, so
rather than invent something new we transferred the proven pattern. Recognizing that a "new" AI
problem is an old data-modeling problem in disguise is itself part of the craft, it keeps you from
over-engineering.

**Why registering a source must be trivial.** We reasoned about the failure mode over time: if
adding a source is a rewrite of the retrieval query, people won't do it, and the knowledge base
quietly stops reflecting reality. So the only per-source work is a *mapping* — one dict that says
"this source's `body` is our `text`, its `created_at` is our `ts`." Make the common extension a
one-liner and it will actually happen; that is how a knowledge base stays current.

**Why pure SQL, with no dispatch.** Elsewhere in the package we go to real lengths to isolate
per-engine divergence. Here we deliberately did the opposite, because unification genuinely *is*
uniform. A `UNION ALL` with casts behaves the same everywhere; there's no AI and no dialect split.
Adding dispatch would be complexity for nothing.

**Why the same-embedding-model rule is stated, not assumed.** A cross-source knowledge base is
precisely where someone would accidentally mix embedding models — tickets embedded with one model,
calls with another, and get rankings that are quietly wrong (the vectors aren't comparable). Since
this is the sharpest edge in the whole feature, we name it as an explicit constraint instead of
hiding it behind an assumption. And lineage returns as non-negotiable for the same reason as in
chunking, now amplified: a hit can come from any system, so "which system and which row" must ride
on every row and into every result, or a cross-source answer becomes an unattributable claim.

## Consequences

- One search answers cross-system questions; every result cites its originating system and row.
- **All sources must be embedded by the same model** — a corpus embedded by one model can't be
  searched with vectors from another (the same invariant that drives
  [ADR-0004](0004-version-aware-incremental-refresh.md)). This is a real constraint on the caller.
- No per-engine divergence (it's `UNION ALL` + casts), so cloud coverage is a liveness/shape check;
  the interesting behavior (cross-source, account-scoped retrieval) is validated deterministically.
- For scale, a managed index over the mart is the opt-in step
  ([ADR-0005](0005-retrieval-brute-force-default-index-opt-in.md)).

## Glossary

- **Knowledge base** — here, a single retrieval-ready table that unifies many source systems about
  the same entities, so one search spans all of them.
- **Conformed dimension** — a data-warehouse pattern: pick one canonical definition/shape and map
  every source into it, so tables modeled separately can be queried together and mean the same thing
  across the business (classically, one shared "customer" dimension that sales, support, and billing
  all conform to). The knowledge base applies the idea to *unstructured* context, one
  retrieval-ready shape that tickets, calls, and emails all conform to.
- **Common shape** — the fixed set of columns every source is mapped to here: `source_type`,
  `source_id`, `account_key`, `text`, `embedding`, `ts`. It *is* the conformed shape.
- **Grain** — what a single row represents in a table: one ticket, one call *turn*, one email. Two
  tables can describe the same account at different grains; conforming them means agreeing on the
  columns without pretending the grains are identical, which is exactly why `source_id` is kept, so
  every unified row is still traceable to its native record.
- **`account_key` / scoping** — the grouping column (account or tenant) you filter on so a search
  returns only one customer's context. "Scoping" a query = restricting it to that key.
- **Lineage** — carrying `source_type` + `source_id` on every row so a retrieval result can cite
  exactly which system and record it came from.
- **`UNION ALL`** — plain SQL that stacks rows from several queries into one result set; the whole
  mechanism here, which is why it's portable across engines with no special functions.
- **Embedding (same model)** — every source must be embedded by the *same* model, or their vectors
  aren't comparable and cross-source ranking is meaningless (see
  [ADR-0004](0004-version-aware-incremental-refresh.md)).
