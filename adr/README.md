# Architecture decision records

This directory holds the architecture decision records (ADRs) for
`dbt_context_engineering`. An ADR captures a single architecturally significant decision:
the context that forced it, the decision itself, and the consequences that follow. The format
is [Michael Nygard's](https://adr.github.io/), kept deliberately short.

This directory is tracked, and ADRs are reviewed with the code that implements them, so the
reasoning ships alongside the change and survives the people who made it.

## Conventions

- One decision per file, named `NNNN-short-title.md`, numbered in order.
- Statuses: `Proposed`, `Accepted`, `Superseded by ADR-XXXX`, `Deprecated`.
- Never edit the decision of an accepted ADR. To change a decision, write a new ADR that
  supersedes it and update the old one's status.
- Copy `template.md` to start a new record.

## Index

- [0001](0001-record-architecture-decisions.md) Record architecture decisions
- [0002](0002-attach-metadata-as-a-separate-macro.md) Attach source metadata as a separate, non-dispatched macro
- [0003](0003-generic-metadata-explicit-provenance.md) Metadata is generic in the transform macro, provenance is explicit in the knowledge base
- [0004](0004-functional-test-parity-across-tiers.md) Functional test parity across all integration tiers
- [0005](0005-in-text-additive-metadata.md) `in_text` embeds metadata in addition to the columns, never instead of them
- [0006](0006-teardown-across-platforms.md) Teardown works on every integration platform to support iteration
