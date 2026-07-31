# 1. Prompts and schemas as versioned Jinja macros

## Status

Accepted, 2026-07-30.

## Concept

A prompt is not documentation, it is a **program input that changes the output**, exactly like a
SQL query or a model definition. The output schema (the JSON shape and its `enum` of allowed
values) is the same: change it and the results change.

Together, a prompt and a schema make a **structured-output** call: the prompt says *what* to do, the
schema says *what shape* to return it in, and the pair coerces the model's free-form prose into
**semi-structured data**, a typed object per row that you can store and query. This is the whole
reason a language model can be used as a *data transformation* at all (prose in, queryable rows out),
and it's why the prompt and its schema travel together as one versioned unit. "Prompts are code"
means we treat these inputs with the discipline we already apply to code like version history,
diffs, code review, reproducibility, and rollback.

The useful analogy is a **database migration**: each version is an immutable, named artifact
(`v3`, `v4`), referenced explicitly, and "improving" one means writing the next version, never
editing a released one in place. The alternative, a prompt living in a warehouse console under a
mutable "latest" pointer, is the equivalent of editing production SQL directly in a query tab: it
works until you need to know *what changed and when*, and then there is no record.

## Context

dbt compiles Jinja into SQL. We want the exact prompt text **embedded as a literal in the compiled
SQL**, so anyone can read the DAG or the compiled artifact and see precisely what was sent to the
model. That rules out "resolve it at run time from somewhere else." Three ways to get the text in:

1. **Read it from a file at compile time.** Infeasible — dbt's Jinja sandbox has no file I/O
   (`open` is not exposed; only `pytz`, `datetime`, `re`, `itertools` are). There is no way to read
   a `.txt` prompt during compilation.
2. **Store prompts in a seed table.** A seed is *data*, loaded at run time; it can't be resolved to
   a compile-time literal to embed in the SQL, and it wouldn't diff as code.
3. **Store each version as a Jinja macro.** Macros are compiled, diffable code, and can return a
   string literal at compile time. This is the path we chose.

## Decision

Each prompt/schema **version is a Jinja macro** on a macro path:
`ce_prompt__<name>__<version>()` and `ce_schema__<name>__<version>()`. The resolvers
`ce_prompt(name, version)` and `ce_schema(name, version)` look the macro up **dynamically by name**
and return its text as a compile-time literal. Versions are explicit and required, there is no
implicit "latest version".

```jinja
-- prompts/signal_classify/v3.sql
{% macro ce_prompt__signal_classify__v3() %}
Classify the sales-call segment below into exactly one signal label.
Segment:
{{ input }}
{% endmacro %}
```

```sql
-- models/signals.sql — the version is right there in the call, and in the compiled SQL
select id,
  {{ dbt_context_engineering.ce_classify('segment',
       dbt_context_engineering.ce_prompt('signal_classify','v3'),
       dbt_context_engineering.ce_schema('signal_classify','v3')) }} as signal
from {{ ref('segments') }}
```

To evolve the prompt you add `v4`; models on `v3` are untouched until you deliberately bump them —
so a change rolls out (and rolls back) one model at a time, and a `git blame` shows who changed the
prompt and why.

## Reasoning

Walk the logic from first principles.

**Why a prompt must be treated as code at all.** For a decade, analytics engineering has learned to
treat its logic — SQL — as code: reviewed, versioned, tested, reproducible. When part of the logic
moves into a *prompt*, the instinct is to treat it as a "setting" you tweak in a console. That is a
category error. The prompt is one of the most important inputs in the pipeline: a one-word change
can flip every downstream label. If it isn't versioned and reviewed, you have reintroduced exactly
the ungoverned, unreproducible mess that dbt was built to eliminate, you've just relocated into the AI
layer. So the first move is non-negotiable: the prompt is code.

**Why "code" here specifically means a compile-time literal.** Given it's code, where should it
live so it's both diffable source *and* auditable in the running system? We wanted two properties at
once: it diffs in a pull request, and the exact text is visible in the compiled SQL and the DAG (so
anyone can see precisely what was sent to the model). That combination forces "resolve it at compile
time and bake it into the SQL", which rules out anything fetched at run time.

**Why a macro, and not a file or a seed.** This is where dbt's own constraints decide it. A file
would be ideal, but the Jinja sandbox has no file I/O, so it's impossible. A seed is *data* loaded
at run time, so it can't become a compile-time literal and wouldn't diff as code. A macro is the only
construct that is simultaneously reviewable code and resolvable at compile time. Making each
*version* its own macro (`__v3`) then buys immutability for free: to change a prompt you write a new
macro, and existing models keep resolving the old one until deliberately bumped, so you get the rollout and
rollback discipline of a database migration, achieved with no extra machinery.

**Why the enum is the single source of truth.** Once prompts and schemas are code, we refused to let
the taxonomy (the label list) exist in more than one place, because a duplicated list silently
drifts. So the schema's `enum` became the one definition, and everything else derives from it: the
classify label set, the conformance test, and the prompt injection for engines that can't carry an
enum. "One definition, many derivations" is a core governance instinct and a taxonomy is
governance.

## Consequences

- The exact prompt/schema is **auditable in the compiled SQL and the DAG**, and shows up in PR diffs
  like any other code.
- Changing a released prompt means a **new version**, never an in-place edit — no silent drift under
  a running model.
- The dynamic name-based lookup relies on a namespace subscript that works in model and
  singular-test render context but **not** in dbt's generic-test capture render. This is why the
  taxonomy-conformance check is shipped as a singular-test macro rather than a generic test
  (see [ADR-0007](0007-context-evaluation-and-groundedness.md)).
- The schema's `enum` becomes the **single source of truth** for a taxonomy: it feeds models (the
  label set for classify), tests (conformance), and is injected into prompts where an engine can't
  carry it natively (see [ADR-0009](0009-portable-enum-enforcement-via-prompt-injection.md)).

## Glossary

- **Context engineering** — the practice of modeling the data that AI systems read (chunking,
  enriching, embedding, governing, retrieving it) as ordinary, tested, version-controlled data
  assets, rather than assembling it ad hoc at query time.
- **Large language model (LLM)** — an AI model that reads and writes natural language; the thing a
  prompt is sent to (e.g. Claude, GPT, Gemini).
- **Prompt** — the natural-language instructions sent to an LLM telling it what to do. Here it's a
  reusable template with an `{{ input }}` placeholder that each row's text is substituted into.
- **Output schema** — a declaration of the structure the model must return (field names, types, and
  allowed values). It turns free-form text into predictable, columnar data.
- **Structured output** — the capability of making a model return data in a *declared shape* (an
  object with named, typed fields) instead of a paragraph of prose. Left to itself an LLM emits
  free-form text; pairing the prompt with an output schema and, where the engine supports it,
  having the API enforce that schema, coerces the answer into a predictable object. This is
  precisely what lets a language model act as a **data transformation** (prose in, queryable rows
  out) rather than a chat interface, and therefore why a prompt can produce semi-structured data at
  all.
- **Semi-structured data** — data with a flexible but inspectable shape, typically JSON-like
  objects/arrays (named fields, sometimes nested), sitting between free text (no structure) and a
  rigid table (fully structured). Warehouses hold it in types like `VARIANT` / `STRUCT` / `JSON`.
  Structured output *produces* semi-structured data — e.g. a `{signal, evidence}` object per row —
  which downstream steps then flatten into scalar columns.
- **Enum (enumeration)** — a fixed, closed set of allowed values, e.g. the labels a classifier may
  return. Also called a **taxonomy**.
- **Jinja / macro** — Jinja is dbt's templating language; a *macro* is a reusable function written
  in it that generates SQL. dbt **compiles** Jinja into plain SQL before running it.
- **Compile-time literal** — a value written directly into the generated SQL at compile time, rather
  than computed later when the query runs. Embedding the prompt as a literal makes the exact text
  visible in the compiled query.
- **DAG** — "directed acyclic graph", dbt's model-dependency graph. "Auditable in the DAG" means you
  can trace exactly what produced what.
- **Generic vs. singular test** — two dbt test styles. A *generic* test is reusable and attached to
  a column in YAML; a *singular* test is a one-off SQL query. Only the latter can resolve a
  versioned prompt/schema by name (hence its use in [ADR-0007](0007-context-evaluation-and-groundedness.md)).
