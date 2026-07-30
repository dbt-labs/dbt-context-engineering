# 1. Record architecture decisions

- Status: Accepted
- Date: 2026-07-30

## Concept

An architecture decision is a **program input to the codebase's future**, not a comment on it. The
code records *what* the package does. A decision record captures *why it is shaped that way* and
*what was rejected to get there*. Left unwritten, that reasoning lives only in a pull request thread
or someone's memory, and both decay.

The useful analogy is **version control for rationale**. Git already versions the code; an ADR
versions the decision behind it, as an immutable, named artifact reviewed in the same pull request
as the change it explains. "Improving" a decision means writing the next record that supersedes the
old one, never editing a released one in place, which is exactly the discipline `git blame` already
gives the code.

## Context

`dbt_context_engineering` makes decisions the code alone does not explain. How macros compose
(`ce_attach_metadata` as a step after `ce_chunk` rather than a flag on it), where per-engine
divergence is allowed (the dispatched aggregation helpers, nowhere else), and how metadata is
modeled (flat in the transform, privileged in the serving mart) are all choices with lasting
consequences and real rejected alternatives. There was no durable, reviewable record of any of them.
A reviewer had nothing to weigh in a pull request, and a future contributor reading the macros had
no answer to "why is it done this way?" other than to reverse-engineer it.

Three ways to keep that reasoning:

1. **Leave it unwritten**, carried by the code and pull request threads. Infeasible as a durable
   record: threads age out of view and contributors leave, so the why evaporates while the code
   remains.
2. **A wiki or external doc.** It drifts from the code because it is edited on a different clock,
   is not reviewed with the change it describes, and is easy to forget to update.
3. **Tracked records in the repository.** They diff in a pull request and are reviewed alongside the
   code that implements them, so the rationale ships with the change. This is the path we chose.

## Decision

**We will keep architecture decision records in a tracked `adr/` directory, one short file per
decision, reviewed alongside the code that implements it.** The format is
[Michael Nygard's](https://adr.github.io/), extended here with Concept, Reasoning, and Glossary
sections so a record explains itself to a non-expert reader.

```text
adr/
  template.md                 copy this to start a record
  0001-record-architecture-decisions.md
  0002-attach-metadata-as-a-separate-macro.md
  ...
```

An ADR is written when a decision is architecturally significant, meaning it does at least one of:

- constrains how future code is structured,
- chooses between real alternatives with lasting trade-offs, or
- would otherwise prompt a "why is it done this way?" later.

Accepted ADRs are immutable. A decision is changed by writing a new ADR that supersedes the old one
and updating the old one's status, never by editing the decision in place.

## Reasoning

**Why record a decision at all.** The most expensive question on a mature codebase is "why is this
the way it is?" asked by someone who was not in the room. Without a record, answering it means
re-deriving the reasoning from the code, which is slow and often wrong, because the code shows the
choice but not the alternatives that were rejected. Writing the decision down once is cheaper than
re-deriving it every time.

**Why in the repository, not a wiki.** We wanted two properties at once: the rationale diffs in a
pull request, and it stays honest against the code. Both force the record to live in the same
repository on the same review path as the change. A wiki satisfies neither reliably, because it is
edited separately and reviewed by no one.

**Why immutable with supersession.** A decision record is only trustworthy if it reflects what was
actually decided at the time. Editing an accepted record in place rewrites history and hides the
change. Superseding instead keeps both the original decision and the reason it was later overturned,
which is the same reason database migrations are append-only rather than edited in place.

## Consequences

- **Rationale is versioned and reviewed with the code**, so it survives contributor turnover instead
  of living only in a thread or a memory.
- **The record ships in the repository**, so a reader has the why next to the what without leaving
  their editor.
- **There is a standing cost**: each significant decision needs a written record, and the log needs
  discipline to stay current rather than drift behind the code.
- **This ADR establishes the practice**; every later record in this directory follows it.

## Glossary

- **Architecture decision record (ADR)**: a short, versioned document capturing one architecturally
  significant decision: the context that forced it, the decision itself, and its consequences.
- **Architecturally significant**: a decision that constrains future code, chooses between real
  alternatives with lasting trade-offs, or would otherwise prompt a "why is it done this way?"
  later. The bar for writing a record.
- **Superseding**: replacing an accepted decision by writing a new ADR that overrides it and
  marking the old one `Superseded by ADR-XXXX`, rather than editing the old record.
- **Michael Nygard format**: the widely used ADR structure (Context, Decision, Consequences) this
  directory follows and extends.
