# 9. Portable enum enforcement via prompt injection

## Status

Accepted.

## Concept

When you ask a model to classify or extract into a fixed taxonomy, there are two places you can tell
it what the allowed values are:

1. **In the structured-output contract** — the schema you hand the API, whose `enum` constrains the
   response. When the engine honors it, this is airtight: the model literally cannot return an
   off-list value.
2. **In the prompt** — plain instructions ("return exactly one of: …"). Softer (the model can still
   stray) but understood by *every* model.

The trap is assuming (1) works everywhere. It doesn't. **Enum enforcement is not portable.** If you
rely on the schema alone and one engine silently drops the enum, that engine's model never learns
the vocabulary and invents its own, and it fails *quietly*, because the call succeeds and returns
well-formed output; it's just the wrong labels.

This is not hypothetical. Confirmed against live output: Snowflake and Databricks carry the enum in
their structured-output format and returned clean labels, but **BigQuery's `output_schema` is a
`name TYPE` list with no way to express an enum**, so it degraded the field to a plain `STRING`. The
BigQuery model, never shown the label set, returned its own taxonomy — `PROBLEM`, `Discovery
Question`, `Objection` (vs. the expected `objection`), `budget_constraint` — and every conformance
test failed 10/10. The extraction itself was correct; the labels were simply off-taxonomy.

## Context

We want one taxonomy definition to constrain the model consistently on all three engines, without
maintaining a second copy of the label list by hand (which would inevitably drift from the schema).

## Decision

**Keep the allowed values in one place, the schema `enum`, and inject them into the prompt on the
engines whose structured output can't carry them.** `ce_augment_prompt(prompt, output_schema)`
prepends an explicit constraint block for each enum field, generated from the schema at compile
time:

```
Follow these value constraints exactly:
- "signal" must be exactly one of these values, copied verbatim
  (do not invent, translate, capitalize, or reformat):
  pain_point, requirement, objection, buying_signal, other

<original prompt…>
```

Only the **BigQuery** wrappers call it. Snowflake/Databricks do **not** inject, their structured
output already enforces the enum, and a constraint preamble would just pollute the model input
(notably `ai_classify`'s text argument). The example prompt no longer hand-lists any labels; the
schema is the sole source.

## Reasoning

**Why the "obvious" choice doesn't work.** There are two places to tell a model its allowed values: the
structured-output contract (airtight *where honored*) and the prompt (soft but universal). The
intuitive pick is the airtight one, but that intuition hides a portability assumption. "Airtight
where honored" quietly depends on every engine honoring it. When one engine *can't* express an enum
and silently degrades it to a plain string, the call still succeeds and returns well-formed output;
only the *values* are wrong. This is the most dangerous failure class in the craft: the **silent**
one. Nothing errors, nothing turns red, and you ship a model that invents its own taxonomy.

**Why we distrusted the contract and verified per engine.** The general lesson this encodes: for
cross-engine AI, never treat "the structured output should enforce it" as a guarantee, confirm what
each engine actually *returns*. Doing that here surfaced behavior no amount of schema-reading would
have predicted: one engine returning `PROBLEM`, `Discovery Question`, `Objection` instead of the
declared labels, and every conformance test failing while the extraction itself was perfectly
correct. You only see silent failures by looking at outputs, not contracts.

**Why fix it in the prompt (and why derive, don't duplicate).** Given the finding, the cheapest and
most robust place to constrain a model is *before* it answers. Stating the rules up front beats
catching violations after with validation-and-retry. But a prompt that hand-lists labels would
create a *second copy* of the taxonomy, destined to drift from the schema. So the fix derives the
prompt text from the schema's `enum` at compile time: the labels still live in exactly one place;
they're merely *injected* where an engine needs them. Single source of truth, honored across
engines.

**Why inject only where needed.** We add the constraint block only on the engine that drops enums,
and not on the engines whose contract already enforces them, because they're the same instruction, it
would be redundant noise polluting the model input (notably a classifier's text argument). 
A fix should be as narrow as the problem.

## Consequences

- The model is constrained to the taxonomy on **every** engine, from a **single source of truth**;
  there is no hand-maintained label list to drift out of sync with the schema.
- Any *future* schema that declares an enum gets this cross-engine constraint automatically with no
  per-prompt work.
- The injection is deterministic string assembly, so it's validated without a warehouse (the
  rendered prompt provably contains the labels); the effect on live BigQuery output is confirmed by
  the conformance tests, which flipped from 10/10 failing to passing once the labels reached the
  model.
- A cross-engine gotcha worth internalizing: **BigQuery silently drops enum constraints.** Any
  taxonomy must reach the model through the prompt, not the schema alone, the injection makes that
  automatic instead of manual.

## Glossary

- **Enum / taxonomy** — a fixed, closed set of allowed values (the labels a classifier may return).
- **Structured-output contract** — the schema you hand the model's API to constrain its response.
  Where the engine honors an `enum` in it, it's airtight: the model literally cannot return an
  off-list value. The load-bearing words are "where honored". If an engine can't express the enum
  and silently ignores it, the contract gives you false confidence rather than enforcement (see
  *silent failure* below). Trusting the contract without verifying per engine is the trap this ADR
  is about.
- **`response_format` / `output_schema`** — the engine-specific names for that contract. Snowflake/
  Databricks `response_format` can carry an `enum`; BigQuery's `output_schema` cannot, and silently
  degrades an enum to a plain `STRING`.
- **Injecting into the prompt** — here this means *adding the allowed values as text in the prompt
  itself* (e.g. "return exactly one of: …"). It is **not** the security term "prompt injection"
  (a malicious input attack); it's the package inserting its own constraint, at compile time.
- **Off-taxonomy** — a returned value that isn't in the allowed set (e.g. `PROBLEM` when the enum is
  `pain_point`). The symptom when a model never saw the label set.
- **Single source of truth** — one authoritative definition (the schema `enum`) that everything else
  derives from, so there's no second copy to drift out of sync.
- **Silent failure** — a failure that produces well-formed but wrong output and no error, so nothing
  turns red. BigQuery dropping the enum is silent: the call succeeds; the labels are just wrong.
