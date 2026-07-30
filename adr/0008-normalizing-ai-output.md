# 8. Normalizing AI output: scalar classify + `ce_text` / `ce_field`

## Status

Accepted.

## Concept

The wrappers made the *call* portable, we use one macro, the right dialect fires. But portability has two
halves: how you **call** the model, and what you do with what **comes back**. The return side is
where the engines diverge most, and it's easy to miss because the call looks identical.

Ask the same three engines for a structured result `{signal, evidence}` and you get three different
*types* back:

| engine | raw return |
|---|---|
| Snowflake | a `VARIANT` object |
| Databricks | a `JSON` **string** |
| BigQuery | a `STRUCT` |

So a column written as `ce_classify(...) as signal` holds a different type on each warehouse, and
every downstream step, like a `WHERE signal = 'pain_point'`, a join, or a conformance test, would have to
branch per engine to read it. That is precisely the divergence the package exists to remove; leaving
it on the output side quietly breaks the promise the moment you try to *use* a result.

The fix is a thin **anti-corruption layer**: small accessors that read each engine's native shape and
hand back the same plain scalar, so downstream SQL never knows which warehouse produced the value.

## Context

`ce_embed` already returns a usable vector, and (after this decision) `ce_classify` returns a plain
label, so those need no accessor. The gap is *structured* results from `ce_generate(..., schema)` and
`ce_extract`, whose shape genuinely differs per engine.

## Decision

Normalize the output side:

- **`ce_classify` returns a scalar label string** on all three engines. The per-engine unwrap lives
  inside each implementation (Snowflake `:labels[0]`, Databricks identity, BigQuery `.<enum-field>`).
  This is a deliberate output-contract change: classify's job is to return *the label*, not an
  engine object.
- **`ce_text(ai_result)`** — the plain text of an *unstructured* `ce_generate` (BigQuery needs
  `.result`; identity elsewhere).
- **`ce_field(ai_result, field, as_type=none)`** — pulls one field out of a *structured* result and
  casts it, dispatching to the right accessor per engine:

  | engine | how `ce_field` reads a field |
  |---|---|
  | Snowflake | `(result):field::type` (VARIANT path) |
  | Databricks | `get_json_object(result, '$.field')` (JSON string) |
  | BigQuery | `(result).field` (STRUCT) |
  | duckdb (default) | `json_extract_string(result, '$.field')` |

```sql
-- one structured call, then flatten to typed scalars — identical downstream on every engine
select
  {{ dbt_context_engineering.ce_field('result', 'signal') }}   as signal,
  {{ dbt_context_engineering.ce_field('result', 'evidence') }} as evidence
from {{ ref('generated') }}   -- result = ce_generate(..., output_schema=…)
```

## Reasoning

**Why "portable call" isn't portable enough.** It's tempting to declare victory once the *call* is
uniform, run one macro, the right dialect fires. But the portability a user actually feels is
end-to-end. If the value that comes back is a VARIANT on one engine, a JSON string on another, and a
STRUCT on a third, then the very next line of SQL, like a `WHERE`, a join, or a test, has to branch per
engine to read it. The divergence you thought you removed simply reappears one step downstream, at
exactly the moment the user tries to *use* the result. So normalization isn't finished until the
output is uniform too.

**Why a thin accessor layer rather than forcing one universal format.** We could have made every
wrapper emit, say, a JSON string everywhere, but that fights each engine's native strengths and
adds conversion cost. The better shape is to *read* each engine's native container and expose a
uniform scalar. That is the anti-corruption-layer pattern from software architecture: let the
foreign representation exist at the boundary, but don't let it leak inward. `ce_field` is that
boundary, past it, everything is a plain scalar and no downstream code knows or cares which
warehouse produced it.

**Why classify returns a scalar (a contract decision).** The *contract* of "classify" is "give me
the label." Returning an engine-specific object instead leaks plumbing into the caller and forces
them to unwrap it. Honoring the contract, always a scalar label, is the wrapper doing its job.

**Why the defensive parentheses (a lesson from reality).** Field access on a *function result* is a
syntax error on some engines (`AI.GENERATE(...).field` won't parse) until you wrap the operand.
That's not something you'd predict from a spec; you learn it by running it. It's a reminder that the
last five percent of cross-engine work is small dialect facts discovered live, which is exactly why
the design keeps a per-engine seam (dispatch) where those facts can be absorbed without disturbing
callers.

## Consequences

- Downstream SQL **never branches on the engine**: flatten once with `ce_field`, then treat the value
  as an ordinary scalar. This is exactly what the conformance test consumes
  ([ADR-0007](0007-context-evaluation-and-groundedness.md)).
- Snowflake's `AI_EXTRACT` returns an envelope `{"error":…, "response":{…}}`; the extract wrapper
  unwraps `:response` so its output matches the others and `ce_field('col','signal')` works uniformly
  (confirmed against live output).
- Field access on a *function result* needs parentheses on BigQuery/Snowflake, so the accessors
  parenthesize the operand defensively, otherwise `AI.GENERATE(...).signal` is a syntax error.
- The default (JSON-string) accessor path is validated deterministically; the per-engine paths are
  confirmed by the live conformance tests.

## Glossary

- **Structured output** — asking a model to return data in a declared shape (named, typed fields)
  instead of free text, by handing it an output schema; it's what turns a chatty model into a *data
  transformation* (full definition in [ADR-0001](0001-prompts-and-schemas-as-versioned-macros.md)).
  The catch this ADR addresses: the *information* is the same across engines, but the *container
  type* it arrives in is not.
- **Semi-structured data** — JSON-like data with named, possibly nested fields, held in warehouse
  types like `VARIANT` / `STRUCT` / `JSON`. Structured output produces it; `ce_field` flattens it
  back to scalars.
- **Scalar** — a single atomic value (one string, one number) as opposed to an object, array, or
  struct. Downstream SQL wants scalars.
- **VARIANT / STRUCT / JSON string** — the three ways the engines return a structured result:
  Snowflake a `VARIANT` (a semi-structured object type), BigQuery a `STRUCT` (a typed record),
  Databricks a `JSON` **string** (text you must parse). Same information, three container types.
- **Accessor** — a small helper that reads a value out of a container. `ce_field` is an accessor:
  give it a field name, it returns that field as a scalar regardless of engine.
- **Anti-corruption layer** — a design-pattern term for a thin translation layer that keeps a
  foreign/messy representation from leaking into the rest of your system. The accessors are one:
  per-engine shapes stop at the boundary; everything downstream sees uniform scalars.
- **Adapter dispatch** — dbt's mechanism for picking an engine-specific implementation behind one
  macro name, so `ce_field` reads a VARIANT on Snowflake and a STRUCT on BigQuery from the same call.
- **Output contract** — the promise a wrapper makes about what it returns. Changing `ce_classify` to
  always return a scalar label is a change to its output contract.
