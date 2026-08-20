# 27. Classification as a second privileged knowledge_base column

## Status

Accepted, 2026-08-20.

## Concept

[ADR-0014](0014-generic-metadata-explicit-provenance.md) already drew the line between the
transform layer (`attach_metadata`, generic, every field a plain column) and the serving contract
(`knowledge_base`, a fixed common shape that promotes exactly the fields it promises consumers).
That record named two kinds of field: **frontmatter** (relational attributes, stays generic) and
**provenance** (a resolvable citation link, promoted). `classify()` output is neither. It is a
**derived label**: a category `classify()` assigns to a row, not a relational attribute of the
source and not a link back to it. This record extends the same principle to that third kind of
field, for a reason specific to `classification` rather than a restatement of ADR-0014's provenance
reasoning: a label only that mart consumers can filter or facet on if every source uses the same
column name for it.

## Context

`classify()` (`macros/functions/classify.sql`) already produces a single-label STRING column a
source model can store upstream, the same relationship `embed()` has to `knowledge_base`, the mart
never calls `classify()` itself, it consumes a column that already exists. Before this record,
`knowledge_base`'s common shape had no slot for it at all: a source that wanted its classification
visible in the mart had no named place to put it, and pass it as an arbitrary extra column, and a
consumer querying across sources would need to know each source's own column name to filter on it,
exactly the per-source knowledge `knowledge_base` exists to remove ([ADR-0006](0006-knowledge-base-union-to-common-shape.md)).

## Decision

**`classification` is a second optional, `NULL`-defaulting column in `knowledge_base`'s common
shape, alongside `citation_url`.** Same mechanism ADR-0014 established for `citation_url`: a named
key in each source's dict, cast to string, `NULL` when a source omits it.

```sql
{{ knowledge_base([
     {'relation': ref('stg_tickets'), 'source_type': 'ticket', 'source_id': 'ticket_id',
      'account_key': 'account_id', 'text': 'body', 'embedding': 'embedding',
      'timestamp': 'created_at', 'citation_url': 'ticket_url', 'classification': 'category'},
     {'relation': ref('stg_calls'), 'source_type': 'call', 'source_id': 'call_id',
      'account_key': 'account_id', 'text': 'transcript', 'embedding': 'embedding',
      'timestamp': 'call_time'},
]) }}
-- 'call' rows get classification = NULL; a consumer can still write
-- filter="classification = 'at_risk'" across every source uniformly.
```

## Reasoning

**Why classification earns a named slot when frontmatter never did.** ADR-0014 did not promote
both of its two field kinds, only one: `citation_url` (provenance) got a named slot, frontmatter
stayed generic and still has no slot today. So this decision is not "add a third slot alongside
two existing ones," it is asking, for a new kind of field, the same question ADR-0014 already
asked and answered differently for its two: does the mart need to guarantee this field the way it
guarantees `citation_url`, or can it stay a plain passthrough column the way frontmatter does?
ADR-0014 drew its line on what a field *is* (relational attribute vs. resolvable link); classify()
output is neither, so that test cannot decide it. This decision draws the line instead on what the
mart needs to *do* with the field: `knowledge_base` exists so a single query answers a cross-system
question without the caller knowing each source's column names. A classification a consumer can
only find by first knowing whether this row came from tickets (`category`) or calls (`topic`)
defeats that promise the same way an unpredictable citation column would; the field is
retrieval-relevant across every source, not source-specific, so it belongs in the common shape.
Frontmatter fails that same test, a customer name or an assignee is useful once you already know
which row you are looking at, not something a cross-source filter needs, which is exactly why it
was right to leave it generic and why that precedent does not change here.

**Why the mechanism is identical to `citation_url`'s, not a new one.** `citation_url` already
proved the exact shape this needs: an optional key, cast to string, `NULL` when a source omits it.
Classification has no different requirement, single-label `classify()` output is a plain string,
so inventing a second mechanism would be complexity with no corresponding new need. Reuse is the
correct move.

**Why scalar only, not multi-label.** `classify()`'s output contract (`macros/functions/classify.sql`)
is a single STRING label; nothing in this package produces multi-label output. Building a
multi-label slot here would be speculative against a shape that does not exist yet, and multi-label
support, if it is ever needed, is a `classify()`-level decision first, `knowledge_base` would only
need to widen the cast once that lands.

## Consequences

- **A retrieval query can filter or facet on classification across every source in the mart**,
  the same way `account_key` already scopes by tenant, without needing to know any source's own
  column name for its label.
- **A source without a classification just omits the key** and gets `NULL`, no forced column, no
  placeholder value.
- No per-engine divergence: this is a cast and a conditional branch in already-portable SQL, the
  same shape `citation_url` uses.
- Related: [ADR-0006](0006-knowledge-base-union-to-common-shape.md) (the common shape this extends),
  [ADR-0014](0014-generic-metadata-explicit-provenance.md) (the transform-vs-contract principle this
  applies to a third field), [ADR-0013](0013-attach-metadata-as-a-separate-macro.md).

## Glossary

- **Derived label**: a category a row is assigned by a classification step (here, `classify()`),
  as opposed to a relational attribute of the source (frontmatter) or a resolvable link back to it
  (provenance). The third kind of field this record distinguishes from ADR-0014's two.
- See [ADR-0014](0014-generic-metadata-explicit-provenance.md)'s glossary for **transform layer**,
  **serving contract**, **frontmatter**, and **provenance**.
