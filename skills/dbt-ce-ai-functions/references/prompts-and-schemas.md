# Authoring prompts & schemas

Prompts and output schemas are **versioned Jinja macros you write in your own dbt project** —
not in the package. This is a deliberate, load-bearing convention (ADR-0001, narrowed by
ADR-0032):

- A prompt is inherently tied to **your** business's taxonomy, so it belongs with your code.
- dbt **Fusion cannot resolve a package's own prompt/schema macros** from a consuming project
  (the package's self-referencing namespace lookup comes up empty). A locally-defined prompt
  resolves correctly on both dbt-core and Fusion.

Nothing should live only in a warehouse UI, prompts are code, versioned and auditable.

## Naming and resolution

| you define (on a macro path in your project) | you call |
|---|---|
| `prompt__<name>__<version>()` → prompt text | `dbt_context_engineering.prompt('<name>', '<version>')` |
| `schema__<name>__<version>()` → JSON-schema string | `dbt_context_engineering.schema_def('<name>', '<version>')` |

The resolver looks the macro up by that exact fully-qualified name in your project's macro
namespace and returns its text as a **compile-time literal** embedded in the compiled SQL (for
auditability). **Versions are explicit and required, there is no implicit "latest."** A missing
name/version raises a clear compiler error naming the macro it expected.

> The resolver macro is `schema_def`, not `schema` — `schema` is a reserved dbt context variable.
> The version macros are still named `schema__...`.

## The `{{ input }}` placeholder and `{% raw %}`

A prompt macro's text contains an `{{ input }}` placeholder where the row's column value is
substituted at compile time by `render_prompt` (whitespace-tolerant: `{{input}}`, `{{ input }}`
all match). To keep that token **literal** in the macro, wrap the body in `{% raw %}...{% endraw %}` 
otherwise dbt tries to render `{{ input }}` when the macro is parsed and the substitution
silently breaks (the literal text `{{ input }}` would be sent to the model).

```jinja
{% macro prompt__fact_extract__v1() -%}
{%- raw -%}
Extract each distinct customer-reported problem from the ticket below.
For every problem, include the verbatim quote that supports it.

Ticket:
{{ input }}
{%- endraw -%}
{%- endmacro %}
```

## The schema `enum` is the single source of truth

Define the allowed label set **once**, in the schema's `enum`. Do not also hand-list labels in
the prompt. That one enum drives:

1. the `classify` label set,
2. the `conforms_to_schema` test (labels stay in-taxonomy),
3. BigQuery prompt-injected enum enforcement (the wrappers copy the enum into the prompt because
   BigQuery's output schema can't express an enum).

```jinja
{% macro schema__fact_extract__v1() -%}
{%- raw -%}
{
  "type": "object",
  "properties": {
    "problem":  {"type": "string", "enum": ["billing", "outage", "bug", "how_to", "other"]},
    "evidence": {"type": "string", "description": "Verbatim quote supporting the label (lineage)."}
  },
  "required": ["problem"],
  "additionalProperties": false
}
{%- endraw -%}
{%- endmacro %}
```

**Always include an evidence/quote field on an extraction schema** — lineage is a package
invariant, and it's what the `grounded` test checks.

## Versioning discipline

- Bump the version (`v1` → `v2`) when you change a prompt or schema in a way that changes model
  output; keep the old macro so historical runs stay reproducible and auditable.
- Because the resolved text is compiled into the SQL, a prompt change is visible in your warehouse
  query history and in the `ai_run_log`.
- Pair with `eval(..., prompt_version='v2')` (see `dbt-ce-pipeline`'s trust reference) to track
  quality across prompt versions over time.

## Where to put them

Any macro path in your project works (dbt's default is `macros/`). Keep a prompt and its schema
together — one file per task/version is a clean convention, e.g.
`macros/prompts/ticket_priority.sql` holding both `prompt__ticket_priority__v1` and
`schema__ticket_priority__v1`.
