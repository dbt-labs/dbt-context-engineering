# Pipeline stages — full macro reference

Every macro is called package-qualified: `dbt_context_engineering.<name>(...)`. Arguments
shown with `=` have defaults and are optional.

## split_sentences

```
split_sentences(relation, id_column, text_column)
```

One row per sentence. Naive `[.!?]` boundaries, identical on every engine (deterministic,
no AI). Output columns: `sentence_id, document_id, sentence_index, sentence_text`. Use it
to produce the per-unit input `chunk` expects, though any table with an id + order + text
works.

## chunk

```
chunk(relation, id_column, order_column, text_column,
      partition_column=none, label_column=none,
      target_tokens=none, overlap_tokens=none, join_separator='\n')
```

Packs ordered units into token-bounded chunks that **never split a unit and never cross a
partition key**. `target_tokens` defaults to `var('chunk_target_tokens', 512)`;
`overlap_tokens` to `var('chunk_overlap_tokens', 0)` (0 = clean, non-overlapping
partition). Token count is the heuristic `ceil(char_length / 4)`, no AI call.

`relation` can be a `ref()`/`source()` **or** the name of an upstream CTE (as a string),
which is how you feed it `split_sentences` output in the same model.

Output columns:

| column | meaning |
|---|---|
| `chunk_id` | stable id of the chunk |
| `partition_key` | the `partition_column` value (or a single global partition) |
| `chunk_seq` | ordinal of the chunk within its partition |
| `source_rows` | **lineage** — ids of every unit packed into this chunk |
| `chunk_text` | the packed text |
| `n_source_rows` | count of units in the chunk |
| `token_estimate` | heuristic token count |
| `exceeds_target` | true if a single unit alone blew the target (feeds `no_oversized_chunks`) |
| `partition_hash` | hash of the partition's ordered inputs (drives incremental) |

Incremental: `chunk` supports `materialized='incremental'` and replaces **whole
partitions** on `partition_key` (never on `chunk_id`: re-chunking changes chunk ids). A
partition-level delta rebuilds only the partitions whose inputs changed.

## attach_metadata

```
attach_metadata(chunks_relation, metadata_relation, metadata_key_column,
                metadata_columns, in_text=false)
```

Left-joins constant-per-key columns from `metadata_relation` onto chunk rows, matching
`partition_key` (or the chunk's key) to `metadata_key_column`. `metadata_columns` is a
list of column names to bring across. With `in_text=True`, each metadata value is also
prepended to `chunk_text` as a `"col: value"` line **in addition to** the columns (never
instead of them): useful when you want the embedding to see the title/source.

The join must be functionally dependent (one metadata row per key). A broken dependency
fans out the join and duplicates `chunk_id` — which a `unique(chunk_id)` test will catch.

## embed

```
embed(input_column, model=none)
```

Row-level embedding of a text column into a vector. `model` defaults to
`var('embedding_model')` and is **pinned** — the whole corpus and every query must use the
same model. Native functions: Snowflake `AI_EMBED`, Databricks `ai_query`, BigQuery
`AI.EMBED`; no DuckDB implementation. Requires `var: ai_functions_enabled = true`.
Materialize as `incremental` for production data (`table` only for a test/example, since it
re-embeds the whole corpus every run), never `view`.

## knowledge_base

```
knowledge_base(sources)
```

Unions several **already-embedded** sources into one common shape:
`source_type, source_id, account_key, text, embedding, ts, citation_url, classification`.
`citation_url` and `classification` are independently optional per source. `sources` is a
list of dicts, each mapping the common-shape columns to expressions/columns in that
source relation. See the package README's knowledge-base section for the exact per-source
spec. The output is a single relation you hand to `vector_search`.

**Order:** build `knowledge_base` *before* `vector_search`. Search runs over the unified
knowledge base, not the individual source tables. With a single source you can skip it and
search the embeddings table directly.

## vector_search

```
vector_search(relation, embedding_column, query_embedding,
              top_k=10, id_column=none, select_columns=none, filter=none)
```

Brute-force cosine similarity — no index. Point `relation` at the `knowledge_base` model (or,
for a single source, the embeddings table). `query_embedding` is usually a nested
`embed('...query text...')` call (same model as the corpus). `select_columns` is a list of
passthrough columns to return alongside the id and score. `filter` is a SQL predicate
string applied before ranking (e.g. restrict to a classification before searching).

Returns `[id_column, select_columns..., score]`, ordered by score descending, tie-broken
on `id_column`. Per-engine scoring differs internally (e.g. BigQuery ranks by
`1 - distance`) but the returned `score` is a cosine similarity on every engine.
`LIVE-VALIDATION DEFERRED` on cloud engines. The brute-force default is validated on
DuckDB.

### Managed index (opt-in, `dbt run-operation` only — never a model)

```
create_vector_index(name, relation, column, attributes=[], warehouse=none,
                    target_lag='1 day', embedding_model=none,
                    distance_type='COSINE', index_type='IVF', storing=[])
```

Builds the engine's external, **separately-billed** index (Snowflake Cortex Search,
BigQuery vector index, Databricks Vector Search). It is stateful with idle-serving cost,
create it deliberately and drop it explicitly when done. Run it as an operation, not as
part of a model build. NEVER create it without being explicitly instructed:

```bash
dbt run-operation create_vector_index --args '{name: my_idx, relation: chunk_embeddings, column: embedding}'
```
