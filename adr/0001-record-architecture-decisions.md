# 1. Record architecture decisions

- Status: Accepted
- Date: 2026-07-30

## Context

`dbt_context_engineering` makes architecturally significant decisions that the code alone does not
explain, such as how macros are composed, where per-engine divergence is allowed, and how metadata
is modeled. There was no durable, reviewable record. A reviewer had nothing to weigh in
a pull request, and a future contributor had nothing explaining why the code is shaped the way it
is. 

We want a durable, reviewable record of decisions that ships with the code.

## Decision

We will keep architecture decision records in a tracked `adr/` directory, using
[Michael Nygard's format](https://adr.github.io/): one short file per decision, with Context,
Decision, and Consequences, numbered `NNNN-short-title.md`.

An ADR is written when a decision is architecturally significant, meaning it does at least one of:

- constrains how future code is structured,
- chooses between real alternatives with lasting trade-offs, or
- would otherwise prompt a "why is it done this way?" later.

Accepted ADRs are immutable. A decision is changed by writing a new ADR that supersedes the old one.

## Consequences

Decisions are versioned and reviewed alongside the code that implements them, so the rationale
survives contributor turnover. There is a small per-decision cost to writing the record, and
discipline is required to keep the log current rather than letting it drift. This ADR establishes
the practice.
