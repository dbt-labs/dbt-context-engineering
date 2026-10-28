# 35. Estimate the whole AI call per row, with the prompt named once in model meta

## Status

Accepted, 2026-10-20.

## Concept

A row sent to `generate`, `classify` or `extract` is billed for more than its own text. The prompt
template and the output schema travel with **every row**, and the model's reply is billed as
**output tokens**. A cost estimate that counts only the row's text describes an `embed` call well
and a generative call badly.

[ADR-0003](0003-cost-as-a-first-class-output.md) made the circuit breaker count estimated **input**
tokens and left output to the response caps. This record keeps both of ADR-0003's tools, the guard
and the meter, and changes what they measure. For a generative model the estimate covers the
**whole call**, meaning input text, prompt template, schema and an output allowance, once per row.

To count the prompt, the guard and the meter must know which prompt the model sends. The model
states that **once**, in its `meta`, and the body and both hooks read it from there.

## Context

`guard_batch` and `log_ai_run` both sized a batch with `estimate_tokens(input_column)`, which is
`ceil(length(text) / 4)` over the input column alone. For `embed` that matches the bill, because an
embedding call sends only the text and returns no output tokens. Billed tokens landed within about
1% of the estimate.

For the generative functions it does not. Every engine wrapper renders the full prompt per row
through `render_prompt`, so the template's characters are sent and billed once per row.
Snowflake and Databricks also send the JSON schema as the response format, and BigQuery prepends
`augment_prompt`'s enum block to the prompt text. On top of that input sits the reply.

Measured on a real Snowflake Cortex extraction workload, by joining `ai_run_log` to
`SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY` on the dbt query comment's
`invocation_id` and `node_id` ([ADR-0033](0033-ai-run-log-node-identity.md)), billed **input**
tokens were about 4x the estimate, and billed input plus output about **6.4x**. `max_est_tokens`
was therefore a ceiling roughly six times looser than configured for these functions, and
`est_tokens` / `est_cost` in `ai_run_log` understated spend by the same factor.

The guard and the meter are hooks in the model's `config()`. They render apart from the model body,
at run time, and never see the prompt or schema that the body hands to the AI function. Passing the
prompt to each hook as an argument works, but a model then names its prompt three times, in the
guard, the meter and the body. A version bump applied to the body and missed in a hook breaks
nothing visibly; the estimate silently undercounts.

## Decision

**A model names its prompt once, in `config(meta={'ai_prompt': {'name': ..., 'version': ...}})`.
The AI function in the body and both hooks read it, and the hooks estimate each row as input text
plus prompt template plus schema plus an output allowance.**

- `config_prompt()` and `config_schema()`, in `macros/prompts/config_prompt.sql`, resolve
  `meta.ai_prompt` through `prompt()` and `schema_def()`. The body passes their results to the AI
  function, whose `prompt` and `output_schema` arguments stay required and explicit. Both helpers
  raise a compiler error when `meta.ai_prompt` is missing. During parse, node config is not yet
  resolved on either engine, so they return placeholders every wrapper accepts: a template holding
  only `{{ input }}`, and a schema with one enum field so `classify` can derive a label set.
- `guard_batch` and `log_ai_run` gain three optional arguments: `prompt`, `output_schema` and
  `output_tokens`. `resolve_call_prompt` fills `prompt` and `output_schema` from `meta.ai_prompt`
  when they are not passed. An explicit argument wins. The schema is optional on this path, since
  an unstructured `generate` has a prompt and no schema.
- A new macro, `estimate_call_tokens`, in `macros/cost/estimate_tokens.sql`, builds the per-row
  expression both hooks use in place of `estimate_tokens`. The prompt term is a compile-time
  constant per row, computed as the template's characters with its `{{ input }}` placeholder
  removed, plus the schema's characters, divided by 4 and rounded up. On BigQuery the template is
  first passed through `augment_prompt`, because that is the text the engine sends.
- The output allowance is `output_tokens` when passed, otherwise `var('est_output_tokens_per_row')`,
  otherwise `var('max_output_tokens')`, otherwise 0. A var declared as `null` falls through to the
  next source. The root `dbt_project.yml` declares `est_output_tokens_per_row: null`.
- With no prompt from either source and no `output_tokens`, the estimate is the input-text term
  alone, exactly as before. `embed` callers keep their current sizing.
- `log_ai_run` emits a warning through `exceptions.warn` when it logs `generate`, `classify` or
  `extract` with no prompt from either source. The message names the model and how to fix it.
  `--warn-error` turns it into a failure.
- `ai_run_log`'s columns are unchanged. `est_tokens` holds the whole-call estimate, and `est_cost`
  continues to price every estimated token at `cost_per_1k_tokens`.

```sql
{{ config(
    meta = {'ai_prompt': {'name': 'my_prompt', 'version': 'v1'}},
    pre_hook = "{{ dbt_context_engineering.guard_batch(ref('stg'), 'text') }}",
    post_hook = "{{ dbt_context_engineering.log_ai_run('extract', relation=ref('stg'),
                    input_column='text') }}"
) }}
select id, {{ dbt_context_engineering.extract('text',
    dbt_context_engineering.config_prompt(),
    dbt_context_engineering.config_schema()) }} as extracted
from {{ ref('stg') }}
```

The rendered per-row expression, compiled on duckdb for a template `abcdefgh{{ input }}` with no
schema:

| vars | compiled expression |
|---|---|
| none | `(ceil(length(x) / 4.0) + 2)` |
| `max_output_tokens: 100` | `(ceil(length(x) / 4.0) + 102)` |
| `max_output_tokens: 100, est_output_tokens_per_row: 7` | `(ceil(length(x) / 4.0) + 9)` |
| no prompt | `ceil(length(x) / 4.0)` |

The warning, as dbt Core prints it when `logged_unprompted` logs a `generate` call with no prompt:

```
[WARNING]: log_ai_run: model.duckdb_tests.logged_unprompted logs a generate call with no prompt, so
est_tokens counts input text only and understates spend. Set config(meta={'ai_prompt': {'name': ...,
'version': ...}}) on the model or pass prompt= to log_ai_run.
```

Fusion prints the same message as `[warning] [JinjaWarn (dbt1071)]`. Under `--warn-error` the build
exits 1 on both engines.

## Reasoning

**Why count the prompt by reading it, not by a hand-set overhead var.** The prompt and schema
already exist as versioned macros ([ADR-0001](0001-prompts-and-schemas-as-versioned-macros.md)),
so their length is known at compile time and exact for each model. A per-project overhead var
would have to be measured and kept in step by hand, and it drifts silently the first time a prompt
changes.

**Why name the prompt in `meta` instead of passing it to each hook.** Passing the same `prompt()`
call to the guard, the meter and the body gives three places to update on a version bump, and a
missed hook fails silently by undercounting. `meta` is node configuration that the body and
the hooks can both read at run time on dbt Core and Fusion, so one entry serves all three. It also
records in the manifest which prompt version each AI model uses.

**Why keep `prompt` a required argument of the AI functions.** Letting `extract` and its siblings
fall back to `meta` on their own would make the prompt implicit at the call site, so a reader of the
body could not see that one is being sent. `config_prompt()` keeps the argument explicit and
only supplies its value, and it raises when `meta` is missing, so no model runs without a prompt by
accident.

**Why a warning and not a hard failure.** `log_ai_run` is the hook that knows the function name,
and for a `table` model it runs as a post-hook ([ADR-0022](0022-log-ai-run-hook-phase-follows-what-this-means.md)).
By then the AI calls have run and been billed, so failing the model would report an error for a
table that was built and paid for. `guard_batch` runs before the spend but does not know which
function the model calls. A warning in the run output surfaces the gap on every run without that
contradiction, and `--warn-error` gives a project that wants it fatal a way to make it so.

**Why not a per-function multiplier.** A factor such as `extract: 6` is calibrated to one workload's
prompt length, input length and reply length. A short prompt over long documents and a long prompt
over short utterances need different factors, and the multiplier would hide the very drift the
meter exists to expose.

**Why the output allowance falls back to `max_output_tokens`.** The guard's job is to refuse a run
that is too big before it starts, and the output side is the part the model controls. The response
cap is the largest reply the engine will bill, so using it when no better figure is set makes the
guard err toward tripping. `est_output_tokens_per_row` exists for a project that has measured its
typical reply and wants `est_cost` closer to actual spend.

**Why apply the prompt and output terms only when a prompt is present.** `embed` sends no template
and returns no output tokens, and its input-only estimate already matches the bill. Keying the new
terms on a prompt keeps every `embed` hook's numbers stable and means it never picks up an output
allowance from a project-wide `max_output_tokens`.

**Why keep the `ai_run_log` columns as they are.** Changing what `est_tokens` measures needs no
schema change to the append-only log, while splitting it into input and output columns would. The
total is what the guard compares against its ceiling.

## Consequences

- **`max_est_tokens` means what it says for generative models.** The ceiling bounds the estimated
  billed tokens of the call, not a fraction of them.
- **`est_tokens` and `est_cost` move toward the bill** for those models, so `ai_run_log` reconciles
  against engine usage history with a much smaller gap.
- **A model names its prompt once**, in `meta.ai_prompt`, and the manifest records which prompt
  version every AI model uses.
- **A generative model logged without a prompt is visible on every run** through `log_ai_run`'s
  warning, and fatal under `--warn-error`.
- **The guard trips sooner** on a generative model whose project sets `max_output_tokens`, because
  that cap becomes part of every row's estimate.
- **Partially supersedes [ADR-0003](0003-cost-as-a-first-class-output.md)** on the guard counting
  input tokens only. ADR-0003's guard, meter and output caps otherwise stand.
- **CI enforces the difference.** Over the 10-row duckdb fixture the input text estimates 176 tokens,
  and `guard_prompted`'s `meta.ai_prompt` prompt, schema and `output_tokens=50` add 200 per row,
  2176 in all. Under `max_est_tokens: 1000`, `guard_pass` builds and `guard_prompted` raises, its
  error reporting:

  ```
  est_tokens=2176 (max max_est_tokens=1000). Raise the ceiling vars or shrink the batch.
  ```

- **CI checks the warning.** `logged_unprompted`, disabled unless `warn_probe` is set, is built on
  purpose and the step fails unless the build passes and its output contains the warning.
- **`assert_call_tokens` checks the logged value on every tier.** It recomputes the per-row overhead
  from the prompt text, not from the macro under test, and asserts `est_tokens` equals the input
  estimate plus that overhead on every row.

## Alternatives considered

- **Pass `prompt` and `output_schema` to each hook.** Rejected: three references per model, and a
  missed version bump in a hook undercounts silently.
- **AI functions fall back to `meta` when `prompt` is omitted.** Rejected: makes the prompt implicit
  at the call site.
- **A Jinja variable in the model, with hook strings built around it.** Rejected: string-built hooks
  are hard to read and fragile to quote.
- **Hand-set per-row overhead var.** Rejected: drifts from the prompt it describes.
- **Per-function multiplier.** Rejected: calibrated to one workload and hides drift.
- **Raise in `guard_batch` when the prompt is missing.** Rejected: requires the guard to take the
  function name, and a warning with `--warn-error` already lets a project make it fatal.
- **Split `est_tokens` into input and output columns.** Rejected for this decision: requires a
  schema migration of an append-only table, and the guard compares a single total.

## Glossary

- **Input tokens**: tokens the engine bills for the text sent to the model, which for a generative
  call includes the prompt template and, on some engines, the schema.
- **Output tokens**: tokens the engine bills for the model's reply, including any "thinking" the
  model does before answering.
- **Prompt template**: the versioned prompt macro's text, with an `{{ input }}` placeholder that each
  row's input text replaces.
- **`meta.ai_prompt`**: the model config entry naming its prompt's `name` and `version`, read by
  `config_prompt()`, `config_schema()`, `guard_batch` and `log_ai_run`.
- **Output allowance**: the per-row number of output tokens the estimate assumes, since the true
  figure is unknown until the model replies.
- **Circuit breaker**: `guard_batch`, the pre-hook that raises before a model runs when its batch
  exceeds `max_batch_rows` or `max_est_tokens`.
- **Meter**: `log_ai_run`, the hook that appends each run's row count and estimated tokens and cost
  to `ai_run_log`.
