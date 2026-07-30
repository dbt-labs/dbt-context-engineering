# 3. Cost as a first-class output: guard + run log

## Status

Accepted.

## Concept

Every other transformation in a dbt project is effectively free to re-run, it's just CPU on a warehouse you
already pay for. **AI calls are not.** Each row sent to a model costs money, and unlike a `GROUP BY`,
the cost is (a) roughly proportional to the data volume and (b) partly *out of your control*, because
the model decides how many output tokens to spend. A model that ships a table of 5 million rows
through an LLM, or one that "thinks" for thousands of tokens per row, can turn a routine `dbt run`
into a surprise invoice.

A one-paragraph primer, because everything here is denominated in them: models read and write
**tokens**, sub-word fragments, roughly four characters of English each, and you are billed per
token, both for what you send (**input tokens**) and what the model returns (**output tokens**). The
catch is that output volume is the *model's* choice: it can spend hundreds of tokens "thinking"
before a one-word answer, and on some models that reasoning is on by default. So an AI bill has a
component you don't directly control and can't see from the input, which is exactly what makes AI
cost different in kind from SQL cost, and why it needs its own controls.

So cost is treated as a **first-class output of the pipeline**, not an afterthought. We use the same
two tools you'd want around any expensive, irreversible operation:

- a **circuit breaker** that refuses to start a run that's too big; and
- a **meter** that records what every run actually consumed (so spend is observable).

A concrete illustration of why the meter isn't enough on its own: Our first live BigQuery generation
run over **10 one-sentence rows** produced **65,825 output tokens (~6,582 per row)**. Almost
all of this was Gemini 2.5's *default "thinking"*, which is billed as output. The inputs were tiny; the
cost was not. Guarding only the input would have waved this through.

## Context

AI enrichment can blow a budget two ways: **input volume** (too many rows × tokens) and **output
volume** (a chatty or "thinking" model). These need different controls, and both must fire *before
or during* the run as a report the next morning is too late.

## Decision

Three coordinated pieces:

- **`ce_guard_batch`** — a **pre-hook circuit breaker**. Before the model runs, it counts the input
  rows and estimated input tokens and **raises** if either exceeds `ce_max_batch_rows` /
  `ce_max_est_tokens`. It was pulled forward to ship alongside the very first AI wrapper, so **no
  unguarded AI call ever exists** in the codebase.
- **`ce_log_ai_run`** — a **post-hook meter**. It appends one row per run (model, function, row
  count, estimated tokens/cost, timestamp, invocation id) to the append-only `ce_ai_run_log` model.
- **Output-side controls** — because the input guard can't see output blow-ups, we have implemented 
  `ce_max_output_tokens` (a cross-engine cap on the response) and `ce_bq_thinking_budget`
  (BigQuery/Gemini only; `0` turns off the default thinking that caused the 65k-token run).

```sql
{{ config(
  pre_hook  = "{{ dbt_context_engineering.ce_guard_batch(ref('stg'), 'text') }}",
  post_hook = "{{ dbt_context_engineering.ce_log_ai_run('classify',
                    model_name=var('ce_model_classify'), relation=ref('stg'), input_column='text') }}"
) }}
select id, {{ dbt_context_engineering.ce_classify('text', ...) }} as signal
from {{ ref('stg') }}
-- guard runs first (raises if the batch is too big); log records the run after it succeeds
```

## Reasoning

**Why cost needs special treatment at all.** Analytics engineers carry an instinct that re-running a
model is essentially free or at least low cost. Models run CPU on a warehouse you already pay for, 
so "just run it again" is the universal safety net. AI breaks that instinct.
Each row costs money, and, uniquely, *part of the spend is the model's decision, not yours* 
(it chooses how many output/thinking tokens to emit). Once "re-run it" is billable and sometimes unbounded, 
cost stops being an accounting detail and becomes a correctness-of-operations concern which is something 
the pipeline itself must manage.

**Why the control must act before/during the run.** A cost report the next morning tells you what
you already spent; it cannot prevent anything. To *prevent*, the control has to fire before the
tokens are spent. That single requirement is why the guard is a pre-hook (it can abort the run)
rather than a dashboard you read afterward.

**Why input and output need separate guards.** This is the non-obvious lesson. Input volume is
knowable in advance, we just count rows and estimate tokens, so one guard can bound it. Output volume is
*not visible from the input at all*, and the live 65k-token run proved this is not theoretical: ten
one-sentence rows produced tens of thousands of output tokens, almost all of it invisible "thinking."
A guard that only checked input would wave that straight through. So we reasoned that input cost and
output cost are genuinely different variables, and each needs its own lever, an input ceiling *and*
an output cap plus a switch for default "thinking."

**Why the guard ships with the first wrapper, not later.** If the guard is optional or arrives in a
later phase, there is always an ungoverned call somewhere, the "we'll add the guard later" idea is how
unguarded AI reaches production. Making it *structurally impossible* to have an unguarded call is
cheaper and safer than relying on discipline. That is what "cost is a first-class output" means in
practice: the safety mechanism is part of the primitive, not something to remember to add later.

**Why log estimates instead of reconciling against real billing.** A payoff-versus-cost judgment.
An estimate-based log is portable, deterministic, and immediately useful for observability; true
reconciliation needs each engine's billing schema, which only exists on a live warehouse and drifts.
So we shipped the high-value, low-cost half now and left reconciliation as something a user can add.
"Ship the portable 80%, fence the engine-specific 20%" recurs throughout this craft.

## Consequences

- No AI model ships without a guard available; the guard's **trip path** (batch over the ceiling →
  raise) is exercised in CI, not just the happy path.
- The run log makes spend **observable and diffable** per run; it is append-only and grows across
  runs (a `--full-refresh` resets it).
- Ceilings are `vars`, so a deliberate large batch is a one-line override, the guard is just a safety
  net.

## Glossary

- **Token** — the sub-word fragment a model actually reads and is billed in (~4 characters of
  English, ~¾ of a word). Everything an LLM does is counted in tokens, so both cost and the model's
  size limits are measured in them; a rough rule is `tokens ≈ characters / 4`.
- **Input vs. output tokens** — input tokens are what you send the model; output tokens are what it
  generates. Output is typically the pricier side *and* the part the model decides, so it's the
  harder half to predict and control.
- **Thinking / reasoning tokens** — output tokens a model spends on internal reasoning *before* its
  visible answer. They bill like any other output but never appear in the response you keep, so
  they're an invisible cost. On some models (e.g. Gemini 2.5) this reasoning is **on by default** and
  can dwarf the answer. The 65,825-token run above was almost entirely thinking over ten
  one-sentence inputs. It is a great example of a cost you cannot see from the input, and the
  reason the input guard alone is not enough.
- **Pre-hook / post-hook** — SQL (or a macro) that dbt runs immediately *before* / *after* building
  a model. The cost guard is a pre-hook (runs first, can abort); the run log is a post-hook.
- **Circuit breaker** — a guard that stops an operation before it does damage, by design failing
  loudly rather than proceeding. Here: refuse a batch that exceeds a row/token ceiling.
- **Append-only incremental model** — a table that grows by adding rows on each run rather than
  being rebuilt. The run log is append-only so history accumulates.
- **`var`** — a dbt variable: a named, overridable setting (e.g. `ce_max_batch_rows`) so limits are
  configuration, not hard-coded.
