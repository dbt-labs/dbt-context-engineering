{#- classify must escape enum labels that contain a single quote (e.g. "Won't renew") on Snowflake and
    Databricks — previously they emitted array('{{ c }}') raw, breaking the build. Compile-time
    assertion calling the impls directly with a quote-bearing enum; raises on regression. Guards #6. -#}
{%- set q = "'" -%}
{%- set label = 'Won' ~ q ~ 't renew' -%}       {# Won't renew #}
{%- set schema = '{"type":"object","properties":{"signal":{"type":"string","enum":["' ~ label ~ '"]}},"required":["signal"]}' -%}
{%- set prompt = 'Classify: ' ~ '{{ input }}' -%}
{%- set out_sf  = dbt_context_engineering.snowflake__classify('utterance_text', prompt, schema, none) -%}
{%- set out_dbx = dbt_context_engineering.databricks__classify('utterance_text', prompt, schema, none) -%}
{%- set errs = [] -%}
{%- if (q ~ q) not in out_sf  -%}{%- do errs.append('snowflake__classify did not escape enum quote -> ' ~ out_sf) -%}{%- endif -%}
{%- if (q ~ q) not in out_dbx -%}{%- do errs.append('databricks__classify did not escape enum quote -> ' ~ out_dbx) -%}{%- endif -%}
{%- if (errs | length) > 0 -%}
    {{ exceptions.raise_compiler_error('classify enum escaping regression: ' ~ (errs | join(' || '))) }}
{%- endif -%}
select 1 as ok where 1 = 0
