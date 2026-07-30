# 3. Metadata is generic in the transform macro, provenance is explicit in the knowledge base

- Status: Accepted
- Date: 2026-07-30

## Context

Two kinds of source-level field show up in this work:

- **Frontmatter**: relational attributes of the source (customer, participants, assignee).
- **Provenance**: a resolvable link back to the source object (citation_url, recording_url) that
  lets an AI consumer cite where an answer came from, not just identify the row.

They also surface in two different places, and those places have different needs:

- `ce_attach_metadata` is a general-purpose transform. Any source can call it with any set of
  columns.
- `ce_knowledge_base` is a serving contract. It merges many pre-embedded sources into one mart with
  a fixed column shape that a single retrieval query reads across all of them.

It would be natural to teach the code the frontmatter-versus-provenance distinction in both places.
Only one of them actually needs it.

## Decision

`ce_attach_metadata` treats every field the same. `metadata_columns` is just a list of column
names; the macro does not know or care whether a given column is frontmatter or provenance, and no
field gets special handling. The caller decides what to pass.

`ce_knowledge_base` does the opposite. `citation_url` is a named, first-class column in the common
mart shape, optional per source. It is singled out deliberately, because a resolvable citation is
part of what the serving mart promises the systems that read it.

## Consequences

The transform macro stays general and reusable. There is no field taxonomy to maintain, and nothing
to misapply when a new source carries fields that are neither cleanly frontmatter nor provenance.

The serving mart guarantees a citation column, so any retrieval result can be traced back to its
source. The cost is a fixed column that sources without a link populate as `NULL`.

The two layers handle provenance differently on purpose. This record exists so that difference
reads as a deliberate choice, not an inconsistency: a general-purpose transform should not hardcode
a special field, and a serving contract should guarantee the fields its consumers depend on. See
[0002](0002-attach-metadata-as-a-separate-macro.md).
