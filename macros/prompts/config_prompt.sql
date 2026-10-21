{#-
  config_prompt() / config_schema() -> the prompt / schema named by the calling model's
  meta.ai_prompt, resolved through prompt() / schema_def(). Lets a model name its prompt ONCE and
  have the AI function in the body and the guard_batch / log_ai_run hooks all read it:

    {{ config(meta={'ai_prompt': {'name': 'my_prompt', 'version': 'v1'}}, ...) }}
    select {{ dbt_context_engineering.extract('text',
                dbt_context_engineering.config_prompt(),
                dbt_context_engineering.config_schema()) }} as extracted

  The AI functions still take prompt / output_schema as explicit arguments; these helpers only
  supply them. Raises when meta.ai_prompt is missing, so a model never silently runs without one.
  During parse, where node config is not yet resolved, they return a placeholder so the body renders.
-#}
{% macro config_prompt() -%}
    {%- set ref_ = dbt_context_engineering.ai_prompt_ref() -%}
    {%- if ref_ is none -%}
        {%- if execute -%}
            {{ exceptions.raise_compiler_error(
                "config_prompt: this model sets no meta.ai_prompt. Add config(meta={'ai_prompt': "
                ~ "{'name': '<prompt>', 'version': '<v>'}}) or pass prompt= directly.") }}
        {%- endif -%}
        {%- set placeholder -%}{%- raw -%}{{ input }}{%- endraw -%}{%- endset -%}
        {{ return(placeholder) }}
    {%- endif -%}
    {{ return(dbt_context_engineering.prompt(ref_['name'], ref_['version'])) }}
{%- endmacro %}

{% macro config_schema() -%}
    {%- set ref_ = dbt_context_engineering.ai_prompt_ref() -%}
    {%- if ref_ is none -%}
        {%- if execute -%}
            {{ exceptions.raise_compiler_error(
                "config_schema: this model sets no meta.ai_prompt. Add config(meta={'ai_prompt': "
                ~ "{'name': '<prompt>', 'version': '<v>'}}) or pass output_schema= directly.") }}
        {%- endif -%}
        {#- parse-time placeholder: one enum field, so classify can derive a label set from it -#}
        {{ return('{"type": "object", "properties": {"label": {"type": "string", "enum": ["placeholder"]}}, "required": ["label"]}') }}
    {%- endif -%}
    {{ return(dbt_context_engineering.schema_def(ref_['name'], ref_['version'])) }}
{%- endmacro %}

{#- resolve_call_prompt(prompt, output_schema) -> [prompt, output_schema, output_tokens] for
    guard_batch and log_ai_run. An argument passed explicitly wins. Otherwise the model's meta
    supplies them: meta.ai_prompt names a prompt and optional schema; meta.ai_vocabulary names a
    vocabulary, whose per-row text depends on the pipeline's method (vocabulary_sent_prompt /
    vocabulary_sent_schema, ADR-0037). The third element is the default output allowance the meta
    implies: 0 for a vocabulary on the decide path, since a decision model returns typed answers,
    not generated text; none otherwise, so estimate_call_tokens applies its usual fallback. -#}
{% macro resolve_call_prompt(prompt=none, output_schema=none) -%}
    {%- set p = prompt -%}
    {%- set s = output_schema -%}
    {%- set out = none -%}
    {%- if p is none -%}
        {%- set ref_ = dbt_context_engineering.ai_prompt_ref() -%}
        {%- set vocab_ = dbt_context_engineering.ai_meta_entry('ai_vocabulary') -%}
        {%- if ref_ is not none -%}
            {%- set p = dbt_context_engineering.prompt(ref_['name'], ref_['version']) -%}
            {%- if s is none -%}
                {%- set schema_macro = context.get('schema__' ~ ref_['name'] ~ '__' ~ ref_['version']) -%}
                {%- set s = schema_macro() if schema_macro is not none else none -%}
            {%- endif -%}
        {%- elif vocab_ is not none -%}
            {%- set p = dbt_context_engineering.vocabulary_sent_prompt() -%}
            {%- if s is none -%}{%- set s = dbt_context_engineering.vocabulary_sent_schema() -%}{%- endif -%}
            {%- if dbt_context_engineering.vocabulary_method() == 'decide' -%}{%- set out = 0 -%}{%- endif -%}
        {%- endif -%}
    {%- endif -%}
    {{ return([p, s, out]) }}
{%- endmacro %}

{#- ai_prompt_ref() -> {'name': ..., 'version': ...} from the current node's meta.ai_prompt, or
    none. -#}
{% macro ai_prompt_ref() -%}
    {{ return(dbt_context_engineering.ai_meta_entry('ai_prompt')) }}
{%- endmacro %}

{#- ai_meta_entry(key) -> the current node's meta[key], or none. Reads `config` first (model body
    and hooks) and falls back to the `model` node. Node config is not resolved during parse on
    either engine, so callers must tolerate none there. -#}
{% macro ai_meta_entry(key) -%}
    {%- set meta = config.get('meta') if config is defined else none -%}
    {%- if not meta and model is defined and model is not none and model.config is defined -%}
        {%- set meta = model.config.get('meta') -%}
    {%- endif -%}
    {%- set entry = (meta or {}).get(key) -%}
    {{ return(entry if entry else none) }}
{%- endmacro %}
