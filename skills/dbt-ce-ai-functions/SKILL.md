---
name: dbt-ce-ai-functions
description: "Use the row-level AI functions from the dbt_context_engineering package in a consuming dbt project: generate (free-form/structured text), classify (single label from a taxonomy), extract (typed structured records), and ai_agg (group-level LLM aggregation), plus authoring the versioned prompt and schema macros they require in your own project and reading structured output back with text() and field(). Use whenever a user wants an LLM to run over their rows in dbt: 'classify each ticket by priority', 'extract facts/fields from documents', 'summarize each call', 'tag rows with a category', 'pull structured JSON out of text', 'aggregate a group with an LLM', 'write a prompt for classify', or 'version my prompts'. Trigger even when the user names only the task ('label these', 'summarize each') without naming a function. For embedding and semantic search see dbt-ce-pipeline; for install and model/cost vars see dbt-ce-setup."
---

# Row-level AI functions with dbt_context_engineering

The package turns an LLM into an ordinary **row-level SQL function**: a prompt becomes a
column. You call the function inside a model's `SELECT`, and each row is processed
independently. This skill covers the four non-embedding functions and the versioned
prompt/schema macros they depend on. (Embedding + search live in `dbt-ce-pipeline`;
installation and model/cost vars live in `dbt-ce-setup`.)

Two things are true of **every** function here:

1. **They cost money and are gated off by default.** Each raises a compiler error unless
   `var: ai_functions_enabled` is `true`, and each needs its model var set
   (`model_generate`/`model_classify`/`model_extract`). See `dbt-ce-setup`.
2. **The model that calls one must be `table` or `incremental`, never `view`** — a view
   re-runs the AI call on every query. The package blocks `view` with a clear error. For a
   scheduled/large job, make it incremental and attach a cost guard + run log (see
   `dbt-ce-pipeline`'s `references/governance-incremental.md`).

## The four functions

Full signatures, output shapes, and per-engine notes are in
`references/functions-reference.md`. At a glance:

| function | asks the model to… | output | schema |
|---|---|---|---|
| `generate` | produce free text (optionally structured) | text, or a structured object | optional |
| `classify` | pick **one** label from a closed set | a scalar string label | **required** |
| `extract` | pull typed fields/records out of text | a structured record | **required** |
| `ai_agg` | reason across a whole **group** at once | text per group (`GROUP BY`) | none (plain instruction) |

### classify — one label from a taxonomy

`classify` needs a prompt and an `output_schema` whose enum defines the allowed labels; it
returns a plain scalar string on every engine.

```sql
select
    ticket_id,
    {{ dbt_context_engineering.classify(
        'ticket_body',
        dbt_context_engineering.prompt('ticket_priority', 'v1'),
        dbt_context_engineering.schema_def('ticket_priority', 'v1')
    ) }} as priority
from {{ ref('stg_tickets') }}
```

### extract — typed records with lineage

`extract` needs a prompt and an `output_schema`; it returns a structured record. **Include an
evidence/quote field in the schema** so each extracted fact carries the source text that
supports it. Lineage is a package invariant and makes the result testable with the `grounded`
test. Read fields back out with `field()` (see below).

### generate — free-form or structured

`generate` needs a prompt; pass an `output_schema` only when you want a structured object
rather than plain text. Read plain text back with `text()`, structured fields with `field()`.

### ai_agg — one answer per group

`ai_agg` runs over a `GROUP BY` and reasons across all rows in each group. Its `prompt` is a
**plain instruction string, not a template** (no `{{ input }}` placeholder). On Databricks it
has no internal map-reduce, so guard each group with `guard_agg_batch` (see `dbt-ce-setup`'s
`max_agg_group_tokens`).

## Authoring prompts & schemas (this lives in YOUR project)

This is the part unique to being a consumer: **prompts and schemas are versioned Jinja macros
you write in your own project, not in the package.** Two reasons; a prompt is tied to your
business's taxonomy, and dbt Fusion cannot resolve a package's own prompt macros from inside
the package (ADR-0001/0032). Read `references/prompts-and-schemas.md` for the full pattern; the
essentials:

- A prompt version is a macro named **`prompt__<name>__<version>()`** returning the prompt text,
  with a `{{ input }}` placeholder where the row's value goes.
- A schema version is a macro named **`schema__<name>__<version>()`** returning a JSON-schema
  string. Its `enum` is the **single source of truth** for the label set. It drives classify,
  the `conforms_to_schema` test, and (on BigQuery) automatic prompt-injected enum enforcement.
- Resolve them with `prompt('name','version')` and `schema_def('name','version')`. **Versions
  are explicit and required, there is no implicit "latest".**

```jinja
{% macro prompt__ticket_priority__v1() -%}
{%- raw -%}
Classify the support ticket below into exactly one priority level.
Return only labels defined in the accompanying schema. Do not invent labels.

Ticket:
{{ input }}
{%- endraw -%}
{%- endmacro %}


{% macro schema__ticket_priority__v1() -%}
{%- raw -%}
{
  "type": "object",
  "properties": {
    "priority": {"type": "string", "enum": ["P0", "P1", "P2", "P3"]}
  },
  "required": ["priority"],
  "additionalProperties": false
}
{%- endraw -%}
{%- endmacro %}
```

The `{% raw %}...{% endraw %}` block is what keeps the `{{ input }}` placeholder **literal**, it
must survive into the prompt text so the function wrappers can substitute the row's column for it
at compile time. Without `{% raw %}`, dbt would try to render `{{ input }}` when the macro is
parsed and the substitution would silently break. Don't hand-list the allowed labels in the
prompt; they live once in the schema `enum` (on BigQuery the wrappers auto-inject them into the
prompt from that single source).

> Note the macro is called `schema_def`, not `schema` — `schema` is a reserved dbt context
> variable. (The version macros are still named `schema__...`.)

## Reading the output back

Wrapper outputs have per-engine shapes; two helpers normalize reading them:

- `text(ai_result)` — the plain text of an unstructured `generate`.
- `field(ai_result, field, as_type=none)` — one field out of a structured `generate`/`extract`
  result, cast to `as_type`. **Flatten with `field()` before** running `conforms_to_schema` on a
  structured result, or before a `grounded` test on an extracted quote.

## Trust & cost (cross-links)

- Test outputs **without spending AI budget**: `grounded` (an extracted quote really appears in
  the source), `conforms_to_schema` (a label stayed in its enum), `eval` (score against a golden
  set). See `dbt-ce-pipeline`'s `references/trust-evaluation.md`.
- Wire a `guard_batch` pre-hook and `log_ai_run`/`complete_ai_run` hooks on every AI model, and
  make large/scheduled ones incremental. See `dbt-ce-pipeline`'s
  `references/governance-incremental.md`.

## Reference files

- `references/functions-reference.md` — exact signatures, required vs optional args, output
  shapes, reading-back helpers, and per-engine notes for generate/classify/extract/ai_agg.
- `references/prompts-and-schemas.md` — authoring `prompt__`/`schema__` macros, the
  `{{ input }}` placeholder, enum-as-single-source-of-truth, versioning discipline, and why
  they live in the consuming project.
