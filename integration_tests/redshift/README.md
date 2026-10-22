# Redshift + Amazon Bedrock integration tests

The Redshift analogue of `integration_tests/cloud`, kept as its own project because Redshift
diverges from the three built-in-AI engines: AI runs through Bedrock **inference UDFs** created with
`CREATE EXTERNAL MODEL` (not inline functions), structured output is **best-effort** (prompt-enforced,
no `response_format`), vector search is a **pure-SQL cosine over `SUPER` arrays**, and the
`embedding_canary` monitor is **unsupported** (it needs a scalar cosine Redshift lacks). See the ADR.

This project **runs real Bedrock calls** (small cost) when the AI models execute.

## Prerequisites (once per warehouse)

1. **Provision the two Bedrock inference functions** (run-operation, never a model build):
   ```bash
   # text model — serves generate/classify/extract/ai_agg. In us-east-2 you MUST use a
   # cross-region inference profile (the us.* id), not the bare model id.
   dbt run-operation create_bedrock_function --profile redshift --args \
     '{function_name: ce_text, model_id: us.anthropic.claude-haiku-4-5-20251001-v1:0, iam_role: default}'

   # embedding model — serves embed/vector_search
   dbt run-operation create_bedrock_function --profile redshift --args \
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
# full battery (real AI calls) — ai_functions_enabled is opt-in per run (safe by default)
dbt build --project-dir integration_tests/redshift --profile redshift \
  --vars '{ai_functions_enabled: true}'
```

`rs_chunks` is **incremental** (`delete+insert`) so a second run exercises the delta path —
`redshift__row_value_not_in`'s correlated `NOT EXISTS` (Redshift has no row-constructor `IN`):

```bash
dbt build --project-dir integration_tests/redshift --profile redshift --vars '{ai_functions_enabled: true}'
dbt build --project-dir integration_tests/redshift --profile redshift --vars '{ai_functions_enabled: true}'  # delta
```

## What it covers

| Model / test | Redshift path exercised |
|---|---|
| `rs_embeddings` + `assert_embeddings` | `embed` (serialize→extract→parse SUPER), `embedding_dimension` (`get_array_length`), `content_hash` (`sha2`) |
| `rs_search` + `assert_search` | `vector_search` — pure-SQL `SUPER` cosine (unnest + `AT`) |
| `rs_sentences` + `assert_sentences` | `split_sentences` — PCRE lookaround sentinel |
| `rs_chunks` + `assert_chunks` | `chunk` — `array_agg` (json_parse SUPER), `string_agg` (listagg), incremental `row_value_not_in` NOT EXISTS |
| `rs_generate` | `generate` + `text`, UNIFIED `maxTokens` cap |
| `rs_classify` + `assert_classify` | best-effort label, on-enum |
| `rs_extract` (+ `topic` not-null test) | best-effort JSON + `field` (`json_extract_path_text`) |

`ai_run_log` (audit) is bootstrapped via `on-run-start`. `embedding_canary` is intentionally not
enabled. CI parses this project connection-free on the `redshift` target (structure gate); the live
build above is run manually with real credentials.
