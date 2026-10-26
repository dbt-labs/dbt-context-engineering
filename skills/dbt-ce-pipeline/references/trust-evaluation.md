# Trust & evaluation

Retrieval and enrichment quality is testable **without spending any AI budget** — every
check here is deterministic SQL that runs in CI on DuckDB. A green `dbt build` should mean 
"the output is correct," not just "the SQL ran."

## grounded (generic test)

Fails any row whose evidence quote is **not actually a substring of its source text** —
the core guard against a model inventing a citation. Attach it to the evidence/quote
column of an extraction or a chunk.

```yaml
# schema.yml
models:
  - name: extracted_facts
    columns:
      - name: evidence
        tests:
          - dbt_context_engineering.grounded:
              source_text_column: chunk_text      # required
              ignore_case: true                    # default true
              normalize_whitespace: true           # default true
              allow_empty: false                   # default false
```

## conforms_to_schema (singular-test macro)

Returns the rows whose value for a column is **not in that column's schema enum** — proving
a classification/extraction stayed inside its declared taxonomy. Flatten a structured
result to a scalar column with `field()` first (see the `dbt-ce-ai-functions` skill).

```sql
-- tests/assert_signal_conforms.sql
{{ dbt_context_engineering.conforms_to_schema(
    relation       = ref('classified_chunks'),
    column         = 'classification',
    schema_name    = 'signal_classify',
    schema_version = 'v3',
    property       = none,        -- for a specific property of a multi-field schema
    allow_null     = false
) }}
```

The schema enum (from your `schema__<name>__<version>` macro) is the single source of
truth, the same enum that drives classification and, on BigQuery, prompt-injected enum
enforcement.

## no_oversized_chunks (generic test)

Attach to `chunk`'s `exceeds_target` column; fails if any chunk exceeded the token target
because a single source unit was itself too large. A signal that a source needs
finer splitting.

```yaml
models:
  - name: chunks
    columns:
      - name: exceeds_target
        tests:
          - dbt_context_engineering.no_oversized_chunks
```

## eval — scoring predictions against a golden column

```
eval(relation, prediction_column, expected_column, prompt_version=none)
```

Scores pre-computed prediction columns against a labelled/golden column and emits **tidy
metric rows** — `metric | label | value` — with overall `accuracy` plus per-label
`precision` and `recall` (computed via a full-outer join of predicted vs actual counts, no
correlated subqueries). Zero AI spend; validates on DuckDB. Pass `prompt_version` to stamp
the rows and materialize the result as an incremental snapshot so you can track quality
drift across prompt versions over time.

```sql
-- models/eval_signal.sql
{{ config(materialized='incremental') }}
{{ dbt_context_engineering.eval(
    relation          = ref('classified_vs_golden'),
    prediction_column = 'predicted_label',
    expected_column   = 'golden_label',
    prompt_version    = 'v3'
) }}
```

## Where each check fits

- **chunk** → `no_oversized_chunks` (structure) + `unique(chunk_id)` (lineage/dependency
  tripwire).
- **attach_metadata** → `unique(chunk_id)` catches a fanned-out join.
- **embed / vector_search** → `not_null` on the embedding; relationship tests from chunks
  back to sources catch orphaned embeddings after a re-chunk.
- **classify / extract** → `grounded` on evidence, `conforms_to_schema` on labels, `eval`
  against a golden set.
