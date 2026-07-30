# Inspection guide

How to read the objects the integration test projects build, as a new user of the package.
The package turns raw text into governed, citable, AI-ready context. Walk the objects in
pipeline order.

Object names in the tables are generic. On the three warehouses the models carry a platform suffix
(`_sf`, `_dbx`, `_bq`). duckdb is the credential-free deterministic tier: it builds the chunking,
metadata, and retrieval-logic models but none of the AI models (generate/classify/extract/embed),
and a few of its model names differ from the generic cloud name (noted inline). Everything builds
into your own dbt target schema (whatever your profile resolves to), so the unqualified table names
in the queries below resolve there; qualify them with your schema if your client is not already
pointed at it.

**Running the queries.** Every query below is written for Snowflake and uses the `_sf` suffix. To
run on another tier, replace `_sf`:

- Databricks: `_dbx`
- BigQuery: `_bq`
- duckdb: drop the suffix entirely. Note duckdb has no AI models, and names a few models
  differently (see the inline notes, e.g. `ce_search` is `ce_search_results` on duckdb).

Exceptions that carry no suffix on any tier, leave them exactly as written: the seeds
(`ce_fixture_documents`, `ce_fixture_utterances`, `ce_fixture_calls`) and the audit log
(`ce_ai_run_log`).

## Inputs: the raw material

| Object | Purpose | What to look for |
|---|---|---|
| `ce_fixture_documents` | Long-form docs as one row each, with `title` + `citation_url` | One row per document, a full-text blob, source-level metadata columns |
| `ce_fixture_utterances` | Transcript as one row per speaker turn | Already atomic, no splitting needed downstream |
| `ce_fixture_calls` | Call-level metadata | `customer`, `participants`, `recording_url`, keyed by `call_id` |

```sql
-- ce_fixture_documents: one row per doc, with the source-level metadata columns
select * from ce_fixture_documents;

-- ce_fixture_utterances: one row per turn, already atomic
select * from ce_fixture_utterances order by call_id, turn_index;

-- ce_fixture_calls: call-level metadata, one row per call_id
select * from ce_fixture_calls;
```

## Chunking: text into token-bounded units

| Object | Purpose | What to look for |
|---|---|---|
| `ce_split_docs` | Splits doc blobs into one row per sentence | More rows than `ce_fixture_documents`; each a single sentence with a stable `sentence_id` |
| `ce_chunk_docs` | Packs sentences into token-bounded chunks | `chunk_id`, `chunk_text`, and `source_rows` (lineage: which sentences went in). No chunk crosses a `document_id` |
| `ce_chunk_utterances` | Same packing over transcript turns | `source_rows` lists utterance ids; no chunk crosses a `call_id` |

```sql
-- ce_split_docs: one row per sentence, more rows than the document seed
select * from ce_split_docs_sf order by document_id, sentence_index;

-- ce_chunk_docs: packed chunks with lineage; every chunk stays within one document (partition_key),
-- no chunk mixes sentences from two documents
select * from ce_chunk_docs_sf order by partition_key, chunk_seq;

-- ce_chunk_utterances: same, over transcript turns; every chunk stays within one call (partition_key),
-- no chunk mixes turns from two calls
select * from ce_chunk_utterances_sf order by partition_key, chunk_seq;
```

## Metadata: making chunks self-describing

| Object | Purpose | What to look for |
|---|---|---|
| `ce_chunk_metadata_cols` | Attaches `title`/`citation_url` as columns only (`in_text=false`) | Same rows as `ce_chunk_docs`, plus two metadata columns; `chunk_text` unchanged |
| `ce_chunk_metadata_text` | Same, but embeds the block into the text (`in_text=true`) | `chunk_text` opens with `title: ...\ncitation_url: ...\n---\n`; larger `token_estimate` |
| `ce_chunk_metadata_utterances` | Same macro, different source, attaches call metadata to transcript chunks | `customer`/`participants`/`recording_url` constant per `call_id`; proves the macro is source-agnostic |

```sql
-- ce_chunk_metadata_cols: metadata as columns, chunk_text untouched
select * from ce_chunk_metadata_cols_sf order by partition_key, chunk_seq;

-- ce_chunk_metadata_text: the "title: ...\ncitation_url: ...\n---\n" block is now inside chunk_text
select * from ce_chunk_metadata_text_sf order by partition_key, chunk_seq;

-- ce_chunk_metadata_utterances: call metadata, constant per call_id
select * from ce_chunk_metadata_utterances_sf order by partition_key, chunk_seq;
```

The one comparison that shows the design: `ce_chunk_docs` next to `ce_chunk_metadata_text`. Same
`chunk_id`, same lineage. The only difference is the metadata columns and the embedded block. The
chunking macro never learned about metadata; a separate composable macro added it.

```sql
-- side by side: raw chunk vs the same chunk with the metadata block embedded
select d.chunk_id, d.chunk_text as raw_text, t.chunk_text as with_block
from ce_chunk_docs_sf d
join ce_chunk_metadata_text_sf t on d.chunk_id = t.chunk_id
order by d.chunk_id;
```

## AI wrappers, one call shape with per-engine dialect underneath (cloud tiers only)

These run real AI calls, so they exist only on the three cloud projects. duckdb has no AI models.

| Object | Purpose | What to look for |
|---|---|---|
| `ce_generate` | Free-text generation over each row | An AI-written column; same macro compiles to Cortex / Databricks / BigQuery SQL |
| `ce_signals` | Classification into a typed label | Constrained output from a versioned prompt + schema |
| `ce_extract` | Structured field extraction | Parsed structured values from raw text |
| `ce_embeddings` | Vector embeddings | An array/vector column, one per row, from a single pinned model |

```sql
-- ce_generate: eyeball the AI-written column against the input row
select * from ce_generate_sf;

-- ce_signals: the label column; values should fall in the prompt's allowed class set
select * from ce_signals_sf;

-- ce_extract: the parsed structured fields
select * from ce_extract_sf;

-- ce_embeddings: one vector per row (wide; keep a small limit)
select * from ce_embeddings_sf limit 3;
```

## Retrieval + governance

| Object | Purpose | What to look for |
|---|---|---|
| `ce_search` (cloud only; duckdb: `ce_search_results` over `ce_search_corpus`) | Cosine ranking of the corpus against a query vector | Ranked rows with a similarity score, no index required. duckdb ranks fixed seed vectors for a deterministic result; the clouds rank real embeddings. |
| `ce_ai_run_log` (all tiers) | Append-only usage/cost log | One row per AI model run, the audit trail every AI call writes via post-hook. On duckdb it is populated by `ce_logged_model`. |

```sql
-- ce_search: ranked rows with a similarity score (duckdb: ce_search_results)
select * from ce_search_sf order by score desc;

-- ce_ai_run_log: one row per AI model run, the audit trail (no suffix on any tier)
select * from ce_ai_run_log order by run_at desc;
```

duckdb also carries deterministic-only models not walked here (`ce_chunk_overlap`, `ce_guard_pass`,
`ce_render_prompt_test`, `ce_kb` / `ce_kb_search`, `ce_versioned`). They exercise package logic that
needs no AI, so they live only on the deterministic tier.
