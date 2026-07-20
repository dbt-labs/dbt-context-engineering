{#-
  ce_bq_model_params(max_output_tokens, thinking_budget) -> a BigQuery `model_params => JSON '...'`
  fragment, or '' when neither knob is set.

  WHY THIS EXISTS (2026-07): BigQuery's AI.GENERATE / AI.GENERATE_TABLE take an optional
  `model_params` JSON that is passed through to the Vertex generateContent request. Two knobs
  matter for cost:

    - maxOutputTokens — hard ceiling on the response. Without it the model runs to its own
      (large) default.
    - thinkingConfig.thinkingBudget — Gemini 2.5 models run DYNAMIC THINKING ON BY DEFAULT, and
      on the BigQuery/Vertex path thinking tokens are billed and counted as OUTPUT tokens. A
      one-sentence classification observed ~6,500 output tokens/row (10-row batch = 65,825) —
      almost entirely thinking. Setting thinkingBudget => 0 disables it; the visible structured
      output is unaffected because output_schema still constrains it.

  The circuit breaker (ce_guard_batch) only guards INPUT tokens, so it cannot catch an output-side
  blowup like this — this is the output-side control.

  Emits camelCase keys (Vertex request-body convention: generationConfig / maxOutputTokens /
  thinkingConfig / thinkingBudget). LIVE-VALIDATION DEFERRED: re-confirm exact key casing against
  the vendor at live-validation time (see ce_generate).
-#}
{% macro ce_bq_model_params(max_output_tokens=none, thinking_budget=none) -%}
    {%- set gen = [] -%}
    {%- if max_output_tokens is not none -%}
        {%- do gen.append('"maxOutputTokens": ' ~ (max_output_tokens | int)) -%}
    {%- endif -%}
    {%- if thinking_budget is not none -%}
        {%- do gen.append('"thinkingConfig": {"thinkingBudget": ' ~ (thinking_budget | int) ~ '}') -%}
    {%- endif -%}
    {%- if (gen | length) == 0 -%}
        {{ return('') }}
    {%- endif -%}
    {{- return("JSON '" ~ '{"generationConfig": {' ~ (gen | join(', ')) ~ '}}' ~ "'") -}}
{%- endmacro %}
