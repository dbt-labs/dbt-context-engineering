{#- str_literal escaping, per engine (findings #5/#6). Quote escaping: duckdb/snowflake/databricks use
    ANSI doubling (`''`); BigQuery uses `\'` (it parses `''` as two adjacent literals and errors — the
    live BigQuery bug this guards). Backslash escaping: doubled on snowflake/databricks/bigquery
    (escape-char engines), left literal on duckdb/ANSI. Compile-time assertion over the per-engine
    impls directly (all four checked from duckdb); raises on regression, emits no rows otherwise. -#}
{%- set bs = '\\' -%}                          {# one backslash #}
{%- set q  = "'" -%}
{%- set inp = 'a' ~ bs ~ "d 'q' z" -%}         {# a\d 'q' z — backslash + quotes, quote NOT at the
                                                  boundary (a trailing quote would abut the wrapper's
                                                  closing quote and create an incidental '' substring) #}
{%- set def_out = dbt_context_engineering.default__str_literal(inp) -%}
{%- set sf_out  = dbt_context_engineering.snowflake__str_literal(inp) -%}
{%- set dbx_out = dbt_context_engineering.databricks__str_literal(inp) -%}
{%- set bq_out  = dbt_context_engineering.bigquery__str_literal(inp) -%}
{%- set errs = [] -%}
{#- quote escaping -#}
{%- if (q ~ q) not in def_out -%}{%- do errs.append('default missing ANSI quote-escape: ' ~ def_out) -%}{%- endif -%}
{%- if (q ~ q) not in sf_out  -%}{%- do errs.append('snowflake missing ANSI quote-escape: ' ~ sf_out) -%}{%- endif -%}
{%- if (q ~ q) not in dbx_out -%}{%- do errs.append('databricks missing ANSI quote-escape: ' ~ dbx_out) -%}{%- endif -%}
{%- if (bs ~ q) not in bq_out -%}{%- do errs.append('bigquery must escape quote as backslash-quote: ' ~ bq_out) -%}{%- endif -%}
{%- if (q ~ q) in bq_out -%}{%- do errs.append('bigquery WRONGLY used ANSI doubled-quote (parsed as adjacent literals): ' ~ bq_out) -%}{%- endif -%}
{#- backslash escaping -#}
{%- if (bs ~ bs) in def_out -%}{%- do errs.append('default WRONGLY escaped backslash (duckdb: literal): ' ~ def_out) -%}{%- endif -%}
{%- if (bs ~ bs) not in sf_out  -%}{%- do errs.append('snowflake did not escape backslash: ' ~ sf_out) -%}{%- endif -%}
{%- if (bs ~ bs) not in dbx_out -%}{%- do errs.append('databricks did not escape backslash: ' ~ dbx_out) -%}{%- endif -%}
{%- if (bs ~ bs) not in bq_out  -%}{%- do errs.append('bigquery did not escape backslash: ' ~ bq_out) -%}{%- endif -%}
{%- if (errs | length) > 0 -%}
    {{ exceptions.raise_compiler_error('str_literal escaping regression: ' ~ (errs | join(' || '))) }}
{%- endif -%}
select 1 as ok where 1 = 0
