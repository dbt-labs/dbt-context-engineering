# Redshift + Amazon Bedrock integration tests

The Redshift analogue of `integration_tests/cloud`, kept as its own project because Redshift
diverges from the three built-in-AI engines: AI runs through Bedrock **inference UDFs** created with
`CREATE EXTERNAL MODEL` (not inline functions), structured output is **best-effort** (prompt-enforced,
no `response_format`), vector search is a **pure-SQL cosine over `SUPER` arrays**, and the
`embedding_canary` monitor + `create_vector_index` are **unsupported** (they need a scalar cosine /
an in-database vector index Redshift lacks). See [ADR-0036](../../adr/0036-redshift-support-bedrock-external-models.md).

It mirrors the cloud project's model/test set (chunk, embed, search, generate, classify, extract,
ai_agg, attach_metadata, knowledge_base, evaluation, and the multi-run delta paths) so the Redshift
tier has functional test parity (ADR-0015) — everything except the two unsupported features above.

This project **runs real Bedrock calls** (small cost) when the AI models execute.

## Profile

The project declares `profile: 'dbt_context_engineering'`, so your `~/.dbt/profiles.yml` needs a
`dbt_context_engineering` profile with a **`redshift` target** (see
[`../sample.profiles.yml`](../sample.profiles.yml)). Every command below selects it with
`--target redshift`.

## Prerequisites (once per warehouse)

1. **Provision the two Bedrock inference functions** (run-operation, never a model build):
   ```bash
   # text model — serves generate/classify/extract/ai_agg. In us-east-2 you MUST use a
   # cross-region inference profile (the us.* id), not the bare model id.
   dbt run-operation create_bedrock_function --target redshift --args \
     '{function_name: ce_text, model_id: us.anthropic.claude-haiku-4-5-20251001-v1:0, iam_role: default}'

   # embedding model — serves embed/vector_search
   dbt run-operation create_bedrock_function --target redshift --args \
     '{function_name: ce_embed, model_id: amazon.titan-embed-text-v2:0, iam_role: default,
       request_type: RAW, response_type: SUPER}'
   ```
   Re-point an existing function with `replace: true`. The default IAM role must carry
   `bedrock:InvokeModel` (e.g. `AmazonBedrockFullAccess`) on the inference-profile ARN **and** the
   foundation-model ARNs in every region the profile routes to, and the models must be access-enabled
   in the Bedrock console for the Region.

2. **Grant ML privileges** to the run user (superuser, once): `GRANT CREATE MODEL TO <user>;`

## Run

```bash
# full-refresh baseline (real AI calls) — ai_functions_enabled is opt-in per run (safe by default)
dbt build --project-dir integration_tests/redshift --target redshift --full-refresh \
  --vars '{ai_functions_enabled: true}'
```

### Incremental / delta paths

The delta models (`content_hash_delta`, `chunk_delta`, `attach_metadata_delta`, `kb_delta`) only
exercise their incremental logic on a **two-build edit sequence** — a `--full-refresh` baseline, then
a second build with an edit var. A plain second `dbt build` does **not** (and in fact trips the
repeat-build artifact described in `TESTING.md`). Run the same phase-2 sequences `TESTING.md`
§4.3/§4.5/§4.6/§4.7 prescribe for the cloud project, with `--target redshift`:

```bash
# §4.3 content-hash delta (expect assert_content_hash_delta row_count = 1)
dbt build --project-dir integration_tests/redshift --target redshift --full-refresh --indirect-selection cautious \
  --select content_hash_delta_stg content_hash_delta ai_run_log fixture_utterances --vars '{ai_functions_enabled: true}'
dbt build --project-dir integration_tests/redshift --target redshift --indirect-selection cautious \
  --select content_hash_delta_stg content_hash_delta ai_run_log assert_content_hash_delta \
  --vars '{ai_functions_enabled: true, ch_edit_id: 5}'

# §4.5 chunk delta;   §4.6 attach_metadata delta;   §4.7 knowledge_base delta — same shape:
#   baseline --full-refresh, then phase-2 with cd_phase: 2 / amd_edit_id: doc_2 / kbd_phase: 2
```

> **Keep `--indirect-selection cautious` on every phase-2 build above.** The selection includes
> `ai_run_log`, so dbt's default *eager* selection also pulls the invocation-scoped
> `assert_run_log`, `assert_run_log_node_id` and `assert_call_tokens` — whose other parents
> (`signals`, `logged_prompted`) this step doesn't build — and they fail by construction, not for
> any real defect (`TESTING.md` §4.11). `cautious` restricts the run to the models/tests named.

These exercise `redshift__row_value_not_in` (the content-hash/partition delta key check), which on
Redshift collapses the tuple to an `md5` key rather than a row-constructor `IN`.

## What it covers

Functional parity with `integration_tests/cloud` — the same models and `assert_*` tests, adapted
where Redshift diverges:

- **Pipeline:** `chunk_docs`/`chunk_utterances`/`chunk_edges`/`chunk_delta` (`chunk`: `array_agg`
  json_parse SUPER, `string_agg` listagg), `split_docs` (`split_sentences` PCRE sentinel),
  `embeddings` (`embed` → SUPER, `embedding_dimension`, `content_hash`), `search` (`vector_search`
  pure-SQL SUPER cosine).
- **AI functions:** `generate`/`generate_text` (+ `text`, UNIFIED `maxTokens`), `signals` (`classify`,
  best-effort on-enum), `extract`/`extract_flat` (+ `field` via `json_extract_path_text`), `ai_agg`
  (LISTAGG collapse → one UDF call), `flatten`.
- **Metadata / KB / eval:** `attach_metadata_delta`, `amd_null_meta*`, `kb`/`kb_hetero`/`kb_delta`,
  `orphan_*`, `eval_metrics`, grounded/conforms.
- **Governance:** `guard_batch`, `log_ai_run`/`complete_ai_run` → `ai_run_log` (bootstrapped via
  `on-run-start`), `version_guard` / `content_hash_delta` incremental re-embed, `dev_sample_filter`
  (`sample_filtered`).

**Not enabled:** `embedding_canary` (monitoring) and `create_vector_index` — unsupported on Redshift.
CI parses this project connection-free on the `redshift` target (structure gate); the live build
above is run manually with real credentials.
