# 14. Metadata is generic in the transform macro, provenance is explicit in the knowledge base

## Status

Accepted, 2026-07-30.

## Concept

The same field can deserve different treatment at different **layers**. A **transform** is a
general-purpose tool: it should make as few assumptions about its inputs as possible, so any caller
can reuse it. A **serving contract** is the opposite: it promises a fixed shape to the systems that
read it, so the fields those systems depend on must be guaranteed, not optional conventions.

The principle is **generality at the transform, guarantees at the contract**. A general tool should
not privilege one field, because privilege is an assumption that limits reuse. A contract should
privilege exactly the fields it promises, because a promise the consumer cannot rely on is not a
contract.

## Context

Two kinds of source-level field show up in this work:

- **Frontmatter**: relational attributes of the source, such as customer, participants, assignee.
- **Provenance**: a resolvable link back to the source object, such as `citation_url` or
  `recording_url`, that lets an AI consumer cite where an answer came from, not just identify the
  row it came from.

They surface in two places with different needs. `attach_metadata` is a general-purpose transform
that any source can call with any set of columns. `knowledge_base` is a serving contract that
merges many pre-embedded sources into one mart with a fixed common shape (`source_type`,
`source_id`, `account_key`, `text`, `embedding`, `ts`, `citation_url`), which a single
`vector_search` reads across all of them.

It would be natural to teach both layers the frontmatter-versus-provenance distinction. Only one of
them actually needs it.

## Decision

**`attach_metadata` treats every field the same; `knowledge_base` promotes `citation_url` to a
first-class column on purpose.** In the transform, `metadata_columns` is just a list of names. The
macro does not know or care whether a column is frontmatter or provenance, and no field gets special
handling. The caller decides what to pass. In the serving mart, `citation_url` is a named slot in
the common shape, optional per source and defaulting to `NULL`, singled out deliberately because a
resolvable citation is part of what the mart promises its consumers.

```sql
-- transform: flat, every column equal
{{ attach_metadata(..., metadata_columns=['title', 'citation_url', 'assignee']) }}

-- serving contract: citation_url is a named, guaranteed slot (NULL when a source omits it)
{{ knowledge_base([
     {'relation': ref('stg_tickets'), 'source_type': 'ticket', 'source_id': 'ticket_id',
      'account_key': 'account_id', 'text': 'body', 'embedding': 'embedding',
      'timestamp': 'created_at', 'citation_url': 'ticket_url'},
]) }}
```

## Reasoning

**Why the transform stays flat.** `attach_metadata` cannot know what fields a future source will
carry. If it hardcoded a frontmatter-versus-provenance taxonomy, every new source with a field that
fits neither category would either be misfiled or force a change to the macro. Treating all columns
as an opaque list means the macro never has to be taught a taxonomy, and never misapplies one.

**Why the mart privileges `citation_url`.** The knowledge base exists so a single retrieval query
can answer "everything about account X" across systems and cite its sources. A citation the consumer
can only sometimes find is not a usable guarantee. Making `citation_url` a fixed column, `NULL` when
absent, means every retrieval result has a known place to look for a link, which is the promise the
serving layer is making.

**Why not teach both layers the distinction.** Symmetry is tempting but wrong here. The two layers
have opposite jobs. Duplicating the taxonomy into the transform would add an assumption that limits
its reuse and buys nothing, since the transform never needs to act on the distinction.

## Consequences

- **The transform stays general and reusable.** There is no field taxonomy to maintain, and nothing
  to misapply when a source carries fields that are neither cleanly frontmatter nor provenance.
- **The serving mart guarantees a citation column**, so any retrieval result can be traced back to
  its source object. The cost is a fixed column that sources without a link populate as `NULL`.
- **The two layers handle provenance differently by design.** This record exists so the difference
  reads as a deliberate choice rather than an inconsistency.
- See [0013](0013-attach-metadata-as-a-separate-macro.md) for why attach is a separate macro.

## Glossary

- **Transform layer**: a general-purpose macro that reshapes data for any caller, here
  `attach_metadata`. Optimized for reuse, so it avoids assumptions about its inputs.
- **Serving contract (mart)**: a model that promises a fixed column shape to its consumers, here
  `knowledge_base`. Optimized for guarantees, so it privileges the fields consumers depend on.
- **Frontmatter**: relational attributes of a source (customer, participants, assignee).
- **Provenance**: a resolvable link back to the source object that lets a consumer cite it.
- **`citation_url`**: the provenance field promoted to a first-class, `NULL`-defaulting column in
  the knowledge base's common shape.
- **Embedding**: a numeric vector representing the meaning of a piece of text, produced upstream by
  `embed` and carried through the mart so results can be searched by similarity.
