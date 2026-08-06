# 7. Context evaluation & groundedness as deterministic tests

## Status

Accepted, 2026-07-30.

## Concept

The rest of the package gets data into a retrievable shape. It does **not** answer the question that
actually matters before an agent reads that data: *is it correct?* Language models fail in three
characteristic ways that ordinary data tests never look for:

1. **Hallucinated evidence** — the model reports a fact and attaches a "supporting quote" that does
   not appear anywhere in the source. The claim looks grounded; it isn't.
2. **Out-of-taxonomy labels** — a classifier told to pick from `{pain_point, requirement, objection,
   buying_signal, other}` returns `PROBLEM` or `Discovery Question`.
3. **Silent regression** — a prompt tweak or model upgrade quietly drops accuracy, and nothing turns
   red.

The key insight is that **checking** these is far cheaper and more deterministic than **producing**
them. You don't need a model to verify a quote is real, you just need a substring test. You don't need a
model to check a label is in a set, you only need set membership. You don't need a model to know
accuracy dropped, you need to compare against a labeled golden set. So evaluation is implemented as
**ordinary dbt tests over already-computed columns**: exact string/set/arithmetic, no warehouse-side
AI, no spend, fully deterministic. This is "unit tests for AI output."

## Context

The package already *required* an evidence/quote field on every extracted fact, but nothing
verified the quote was real. A required-but-unchecked field is a false sense of safety. And because
these checks are deterministic, they can run on every change, credential-free.

## Decision

Three checks, each a normal dbt test:

- **`grounded`** — a generic (schema.yml) test: the evidence quote must appear in its source-text
  column (case/whitespace normalization on by default, so trivial formatting differences don't
  false-fail). A hallucinated quote → a failing row → a red build.
  ```yaml
  columns:
    - name: evidence
      tests:
        - dbt_context_engineering.grounded: { source_text_column: segment_text }
  ```
- **`conforms_to_schema`** — a singular-test macro: a classify/extract column may only hold values
  from the `schema` enum. It's a **macro used in a singular test, not a generic test**, because
  resolving a versioned schema by name needs the dynamic namespace subscript that dbt's generic-test
  capture render can't do (see [ADR-0001](0001-prompts-and-schemas-as-versioned-macros.md)).
- **`eval`** — scores predictions against a golden/expected column into tidy `metric, label,
  value` rows (accuracy + per-label precision/recall). Threshold a metric with a test to **gate** a
  prompt/model change: if accuracy drops below the bar, the build fails.
  ```sql
  -- 8-row golden set with 6 correct → accuracy 0.75
  {{ dbt_context_engineering.eval(ref('predictions'), 'predicted_label', 'expected_label') }}
  ```

## Reasoning

**Why a whole new category of test is needed.** The rest of the pipeline answers "is the context
*shaped* right?", the correct columns, types, and ranges. None of it answers "is it *correct*?" And
AI output fails in ways ordinary data tests never probe: a value can be perfectly well-formed, right
type, in-range, non-null, and still be something the model completely fabricated. Type checks
pass; the content is a lie. So correctness for AI output requires tests aimed specifically at
model-*behavior* failures, not data-*shape* failures.

**The pivotal insight: checking is far cheaper than generating.** This is what makes the whole thing
practical. *Generating* a grounded quote needs a model; *checking* that a quote is grounded needs
only a substring test. *Generating* a correct label needs a model; *checking* it's in the taxonomy
needs only set membership. *Scoring* accuracy needs only comparison to a hand-labeled golden set.
Every verification is deterministic string/set/arithmetic, no model needed, no spend, no randomness. That
asymmetry is precisely what lets evaluation run on *every* pull request like an ordinary test suite,
instead of being an expensive, occasional, human-run ritual. The general craft lesson: wherever you
can, verify AI output with non-AI checks.

**Why groundedness is the highest-leverage single check.** It converts a convention we already
required, every extracted fact must carry its verbatim evidence quote, from an honor system into an
enforced invariant. A required-but-unchecked field is a false sense of safety; the check makes a
hallucinated quote fail the build. And grounded evidence is the entire difference between a citation
you can trust and one you can't, which is the whole point of context an agent will quote to a human.

**Why conformance is a singular-test macro, not a generic test.** Not a preference, a platform
constraint. Resolving a schema by name needs a dynamic lookup that dbt's generic-test rendering
can't perform. We let the constraint dictate the shape rather than fight it, and wrote down *why*, so
the next person doesn't "tidy" it back into a generic test and silently break it.

## Consequences

- Groundedness is the highest-leverage check: it converts the "carry your source text" convention
  into an **enforced invariant**. Combine it with extract to get citations you can trust.
- All three run credential-free and deterministically, so they gate every PR, the "is it correct?"
  question is answered continuously, not once by hand.
- The only per-engine divergence is the containment / whitespace primitives (`contains`,
  `collapse_ws`), isolated behind dispatch.
- Validated in both directions — passes on good data **and** catches deliberately planted bad data
  (a hallucinated quote, an invented label, a wrong metric).

## Glossary

- **Evaluation (eval)** — measuring the quality of AI output, ideally automatically and repeatably,
  so you can tell whether a change made things better or worse.
- **Groundedness** — whether a model's stated support for a claim is actually present in the source.
  A grounded quote appears verbatim in the source text; an ungrounded one was made up.
- **Hallucination** — when a model produces confident output that isn't supported by its input
  e.g. inventing a quote, a fact, or a citation. Groundedness checks catch the quote form of this.
- **Evidence quote** — the verbatim snippet of source text a model must return alongside an
  extracted fact, so the fact can be traced and verified.
- **Taxonomy / enum** — the fixed set of allowed labels a classifier may return.
- **Golden set** — a small, hand-labeled dataset with known-correct answers, used as the yardstick
  to score model predictions against.
- **Accuracy** — the fraction of *all* predictions that exactly match the expected label. A useful
  headline number, but it can hide per-label problems (a rare label can be mis-handled while overall
  accuracy still looks high) — which is why precision and recall are reported per label too.
- **Precision (per label)** — of the rows the model *called* label X, the fraction that truly were
  X. High precision = "when it says X, believe it." *Example: it labels 4 rows `objection`, 3 are
  actually objections → precision = 0.75.*
- **Recall (per label)** — of the rows that truly *were* label X, the fraction the model caught.
  High recall = "it rarely misses an X." *Example: 5 rows are truly `objection`, it found 3 → recall
  = 0.6.* Precision and recall trade off, tuning to catch more X's usually admits more false X's —
  so `eval` reports both and you decide which matters for your use case.
- **Generic vs. singular test** — a reusable YAML-attached dbt test vs. a one-off SQL test. Grounding
  ships as a generic test; conformance ships as a singular-test macro (it needs to resolve a schema
  by name — see [ADR-0001](0001-prompts-and-schemas-as-versioned-macros.md)).
- **Deterministic** — no randomness: the same input always gives the same result, so these checks
  can assert exact outcomes and run on every change without a warehouse or AI spend.
