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

{#- resolve_call_prompt(prompt, output_schema) -> [prompt, output_schema] for guard_batch and
    log_ai_run. An argument passed explicitly wins; otherwise both come from meta.ai_prompt. The
    schema is optional here, since an unstructured generate has a prompt and no schema. -#}
{% macro resolve_call_prompt(prompt=none, output_schema=none) -%}
    {%- set p = prompt -%}
    {%- set s = output_schema -%}
    {%- if p is none -%}
        {%- set ref_ = dbt_context_engineering.ai_prompt_ref() -%}
        {%- if ref_ is not none -%}
            {%- set p = dbt_context_engineering.prompt(ref_['name'], ref_['version']) -%}
            {%- if s is none -%}
                {%- set schema_macro = context.get('schema__' ~ ref_['name'] ~ '__' ~ ref_['version']) -%}
                {%- set s = schema_macro() if schema_macro is not none else none -%}
            {%- endif -%}
        {%- endif -%}
    {%- endif -%}
    {{ return([p, s]) }}
{%- endmacro %}

{#- ai_prompt_ref() -> {'name': ..., 'version': ...} from the current node's meta.ai_prompt, or
    none. Reads `config` first (model body and hooks) and falls back to the `model` node. -#}
{% macro ai_prompt_ref() -%}
    {%- set meta = config.get('meta') if config is defined else none -%}
    {%- if not meta and model is defined and model is not none and model.config is defined -%}
        {%- set meta = model.config.get('meta') -%}
    {%- endif -%}
    {%- set ref_ = (meta or {}).get('ai_prompt') -%}
    {{ return(ref_ if ref_ else none) }}
{%- endmacro %}
