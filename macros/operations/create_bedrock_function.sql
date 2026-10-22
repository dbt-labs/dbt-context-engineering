{#-
  create_bedrock_function — OPT-IN, run-operation ONLY. Provisions a Redshift ML "external model"
  over Amazon Bedrock and mints the inference UDF the AI wrappers call. Redshift (unlike Snowflake /
  Databricks / BigQuery) has NO built-in inline AI function: an inference function must be created
  once with CREATE EXTERNAL MODEL before generate/classify/extract/embed/ai_agg can run. That is a
  stateful, IAM-bound setup step — never something a model build should do implicitly — so it lives
  here as a run-operation, exactly like create_vector_index.

    # text model (Converse/UNIFIED) — serves generate, classify, extract, ai_agg:
    dbt run-operation create_bedrock_function --args '{function_name: ce_text,
        model_id: anthropic.claude-3-5-sonnet-20240620-v1:0, iam_role: arn:aws:iam::<acct>:role/<role>}'

    # embedding model (RAW Titan) — serves embed:
    dbt run-operation create_bedrock_function --args '{function_name: ce_embed,
        model_id: amazon.titan-embed-text-v2:0, iam_role: arn:aws:iam::<acct>:role/<role>,
        request_type: RAW, response_type: SUPER}'

  Point the vars at the FUNCTION names this creates (on Redshift the model vars name a UDF, not a
  model string): var model_generate: ce_text, var embedding_model: ce_embed.

  ⚠️ The IAM role needs Bedrock access (e.g. AmazonBedrockFullAccess) and a redshift.amazonaws.com
  trust policy; the target Bedrock model must be enabled in the account/Region. Throughput is bound
  by Bedrock's per-model quotas — large batches can throttle. See the AWS docs for CREATE EXTERNAL
  MODEL and the Redshift-Bedrock integration.

  Args:
    function_name  the inference UDF to create (what the AI wrappers will call).
    model_id       the Bedrock model id (e.g. 'anthropic.claude-3-5-sonnet-20240620-v1:0').
    iam_role       ARN of the Bedrock-enabled role Redshift assumes.
    request_type   'UNIFIED' (default; Converse, message models) or 'RAW' (e.g. Titan embeddings).
    response_type  optional; 'SUPER' to get the raw response object (required for RAW embeddings).
    prompt/suffix  optional static prefix/suffix baked into the model (the wrappers build the full
                   prompt per-call, so these are normally left unset).
    model_name     the external-model object name; defaults to '<function_name>_model'.
-#}

{% macro create_bedrock_function(function_name, model_id, iam_role, request_type='UNIFIED',
                                 response_type=none, prompt=none, suffix=none, model_name=none,
                                 replace=false) -%}
    {%- if target.type != 'redshift' -%}
        {{ exceptions.raise_compiler_error(
            "create_bedrock_function is Redshift-only (CREATE EXTERNAL MODEL over Amazon Bedrock). "
            ~ "Current target is '" ~ target.type ~ "'; those engines expose built-in AI functions "
            ~ "and need no provisioning step.") }}
    {%- endif -%}
    {%- set model_name = model_name or (function_name ~ '_model') -%}
    {% do log("create_bedrock_function: creating external model '" ~ model_name ~ "' + inference "
              ~ "function '" ~ function_name ~ "' over Bedrock model '" ~ model_id ~ "'. run-operation only.",
              info=true) %}
    {%- set ddl -%}
create external model {{ model_name }}
    function {{ function_name }}
    {% if iam_role == 'default' %}iam_role default{% else %}iam_role '{{ iam_role }}'{% endif %}
    model_type bedrock
    settings (
        model_id '{{ model_id }}'
        {%- if request_type %},
        request_type {{ request_type }}
        {%- endif %}
        {%- if response_type %},
        response_type {{ response_type }}
        {%- endif %}
        {%- if prompt is not none %},
        prompt {{ dbt_context_engineering.str_literal(prompt) }}
        {%- endif %}
        {%- if suffix is not none %},
        suffix {{ dbt_context_engineering.str_literal(suffix) }}
        {%- endif %}
    )
    {%- endset -%}
    {% if execute %}
        {#- Redshift has no CREATE OR REPLACE for external models, so re-pointing a function to a new
            model_id (e.g. after a Bedrock model reaches end-of-life) needs an explicit drop first.
            DROP MODEL also drops its inference function. Opt-in via replace=true so a normal create
            never silently destroys an existing model. -#}
        {% if replace %}
            {% do run_query("drop model if exists " ~ model_name) %}
            {% do log("Dropped existing model (replace=true): " ~ model_name, info=true) %}
        {% endif %}
        {% do run_query(ddl) %}
        {% do log("Created Bedrock inference function: " ~ function_name, info=true) %}
    {% endif %}
    {{ return(ddl) }}
{%- endmacro %}
