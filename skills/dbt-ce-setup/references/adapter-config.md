# Per-adapter configuration

Working configuration per warehouse. The model/embedding values below are examples proven in
the package's own cloud integration tests, confirm the exact model names available in your
account/region.

## Snowflake (Cortex)

Native Cortex functions (`AI_COMPLETE`, `AI_EMBED`, `AI_CLASSIFY`) — no connection object or
`CREATE MODEL` needed.

```yaml
vars:
  ai_functions_enabled: true
  embedding_model: 'snowflake-arctic-embed-m-v1.5'   # 768-dim
  model_generate:  'mistral-large2'
  model_classify:  'mistral-large2'
  model_extract:   'mistral-large2'
  # Only if you enable the embedding canary (monitoring): Snowflake VECTOR needs a literal dim.
  embedding_canary_vector_dimension: 768             # match your embedding_model's output dim
```

Notes:
- **`classify` on Snowflake ignores `model_classify`.** `snowflake__classify` uses `AI_CLASSIFY`,
  which selects its own model — `model_classify` is only read on BigQuery. Setting it here is
  harmless (and keeps your config portable across engines), but on a Snowflake-only project
  `classify` needs just `ai_functions_enabled` + its per-call prompt/schema. `model_generate` /
  `model_extract` *are* used on Snowflake (they feed `AI_COMPLETE`).
- `max_output_tokens` maps to `AI_COMPLETE`'s `max_tokens` (applies to `generate`; `classify`/
  `extract` are bounded by their output schema, no separate cap).
- No thinking-budget knob, Cortex models don't run Gemini-style default thinking.

## Databricks

AI functions (`ai_query`, `ai_classify`) require DBR 15.4 LTS or above and are not available on Databricks SQL Classic. 
DBR 18.2+ is RECOMMENDED, not required, and Pro is supported.

```yaml
vars:
  ai_functions_enabled: true
  embedding_model: 'databricks-gte-large-en'
  model_generate:  'databricks-claude-haiku-4-5'
  model_classify:  'databricks-claude-haiku-4-5'
  model_extract:   'databricks-claude-haiku-4-5'
  # ai_agg on Databricks has no internal map-reduce, so a per-group guard is required:
  max_agg_group_tokens: 100000
```

Notes:
- `max_output_tokens` maps to `ai_query`'s `max_tokens`.
- Structured output uses an OpenAI-style `json_schema` envelope internally (handled by the
  package); you just supply the schema via `schema_def`.

## BigQuery (Vertex AI / Gemini)

Enable the Vertex AI API for the project. The `AI.*` GA functions (`AI.GENERATE`, `AI.EMBED`)
call a Gemini endpoint directly.

```yaml
vars:
  ai_functions_enabled: true
  embedding_model: 'text-embedding-005'
  model_generate:  'gemini-2.5-flash'
  model_classify:  'gemini-2.5-flash'
  model_extract:   'gemini-2.5-flash'
  bq_connection:   null            # e.g. 'us.my_vertex_connection' — see below
  bq_thinking_budget: 0            # Gemini 2.5 bills default "thinking" as OUTPUT tokens
  max_output_tokens: 1024
```

Notes:
- **`bq_connection`** is *optional* for interactive queries — End-User Credentials cover them.
  It is needed for service-account, long-running, or batch jobs. When set, the wrappers pass
  `connection_id`. (`bq_model` is only for the legacy `ML.*` path, out of scope for these
  wrappers.) The package's `dbt_project.yml` comment historically labelled `bq_connection`
  "required"; the current guidance is *optional for interactive* — set it if your jobs are not
  interactive.
- **`bq_thinking_budget: 0`** is the single most impactful BigQuery cost setting for structured
  tasks ,Gemini 2.5 runs dynamic thinking on by default and bills it as output tokens.
- BigQuery `output_schema` cannot express an enum; the package injects enum labels into the
  prompt automatically (you still define the enum once in your `schema_def`).

## Redshift (Amazon Bedrock)

Redshift has **no inline AI function**. Each AI call goes through a Bedrock **inference UDF** you
create once with `CREATE EXTERNAL MODEL` — the package ships a run-operation for it. So on Redshift
the model vars name a **UDF**, not a model string.

**Step 1 — provision the inference UDFs (once, run-operation only, never a model build):**

```bash
# text model — serves generate / classify / extract / ai_agg (UNIFIED/Converse)
dbt run-operation create_bedrock_function --args \
  '{function_name: ce_text, model_id: us.anthropic.claude-haiku-4-5-20251001-v1:0, iam_role: default}'

# embedding model — serves embed / vector_search (RAW, returns SUPER)
dbt run-operation create_bedrock_function --args \
  '{function_name: ce_embed, model_id: amazon.titan-embed-text-v2:0, iam_role: default,
    request_type: RAW, response_type: SUPER}'
```

Re-point an existing UDF with `replace: true` (Redshift has no `CREATE OR REPLACE` for external
models, so the macro drops-then-recreates). `iam_role` takes the keyword `default` (the cluster's
default role) or an explicit `'arn:aws:iam::...:role/...'`.

**Step 2 — point the vars at those UDF names:**

```yaml
vars:
  ai_functions_enabled: true
  embedding_model: 'ce_embed'    # the embedding UDF name (NOT a model string)
  model_generate:  'ce_text'     # the text UDF name; classify/extract fall back to it
  # model_classify / model_extract optional — default to model_generate (ce_text)
  max_output_tokens: 1024        # maps to the UNIFIED maxTokens inference-config key
```

Prerequisites / notes:
- **`GRANT CREATE MODEL TO <user>;`** once (superuser), or `CREATE EXTERNAL MODEL` fails with
  `permission denied for language mlfunc`.
- The **IAM role** (keyword `default` or an ARN) needs `bedrock:InvokeModel` — e.g.
  `AmazonBedrockFullAccess` — on the inference-profile ARN **and** the foundation-model ARNs in
  every region a cross-region profile routes to, plus a `redshift.amazonaws.com` trust policy.
- **Enable model access** for the chosen model in the Bedrock console for the Region.
- In regions like **us-east-2 you must use a cross-region inference profile id** (`us.*` /
  `global.*`), not the bare `anthropic.*` model id (on-demand to the base id raises a
  `ValidationException`). UNIFIED inference-config keys are **camelCase & case-sensitive** (`maxTokens`).
- **No idle cost.** `CREATE EXTERNAL MODEL ... MODEL_TYPE BEDROCK` creates a metadata object + UDF
  only; you pay per-invocation Bedrock tokens, with no endpoint or provisioned throughput (unlike
  SageMaker-backed Redshift ML).
- **Structured output is best-effort** (Bedrock returns plain text) and the **embedding canary is
  unsupported** on Redshift — see the `dbt-ce-ai-functions` and `dbt-ce-pipeline` skills.

## Quick pick matrix

| var | Snowflake | Databricks | BigQuery | Redshift |
|---|---|---|---|---|
| `embedding_model` | `snowflake-arctic-embed-m-v1.5` | `databricks-gte-large-en` | `text-embedding-005` | `ce_embed` (a UDF name) |
| `model_generate` | `mistral-large2` | `databricks-claude-haiku-4-5` | `gemini-2.5-flash` | `ce_text` (a UDF name) |
| connection needed? | no | serverless warehouse (DBR 15.4 LTS or above) | `bq_connection` for non-interactive only | provision Bedrock UDFs + `GRANT CREATE MODEL` + IAM `bedrock:InvokeModel` |
| thinking budget | n/a | n/a | `bq_thinking_budget: 0` for structured | n/a |
| canary dimension | `embedding_canary_vector_dimension` (literal) | n/a | n/a | canary unsupported |
