{#-
  str_literal(s) -> a PORTABLE SQL string-literal expression for s.

  Two hazards, handled here so callers (render_prompt, classify's category arrays, …) never emit
  broken or corrupted SQL from arbitrary prompt/label text:

  1. Newlines: BigQuery rejects a raw newline inside a single-quoted literal (Snowflake/Databricks/
     duckdb accept it), so newlines are emitted as chr(10) concatenation, valid on all engines:
         "a\nb"  ->  'a' || chr(10) || 'b'
  2. Backslash: genuinely per-engine, so str_literal is DISPATCHED. Snowflake, Databricks, and
     BigQuery treat backslash as an escape character inside single-quoted literals, so a prompt
     containing `\n`, a regex `\d+`, or a path `C:\Users` would either error (invalid escape) or be
     silently corrupted (`\n` -> a real newline). Those engines must DOUBLE the backslash. duckdb and
     ANSI SQL treat backslash as a literal character, so doubling it there would WRONGLY produce two
     backslashes — the default impl must NOT escape it.
  3. Single quote: ALSO per-engine. duckdb/Snowflake/Databricks accept the ANSI doubling (`''`).
     BigQuery does NOT — it reads `'a''b'` as two adjacent string literals and raises
     "concatenated string literals must be separated by whitespace"; it needs a backslash-escaped
     quote (`\'`) instead. So BigQuery escapes both `\` and `'` backslash-style.
  (This per-engine divergence is exactly why a single shared implementation was a latent bug.)
-#}
{% macro str_literal(s) -%}
    {{ return(adapter.dispatch('str_literal', 'dbt_context_engineering')(s)) }}
{%- endmacro %}


{#- Shared builder.
    escape_backslash: double `\` before splitting (engines where `\` is an escape char).
    quote_escape: how to represent a single quote inside the literal — `''` (ANSI, most engines) or
    `\'` (BigQuery).
    Order matters — escape backslashes FIRST (so a `\'` we add for a quote is not itself doubled),
    then split on the newline CHARACTER (distinct from a literal backslash-n), then escape quotes. -#}
{% macro _ce_str_literal(s, escape_backslash, quote_escape="''") -%}
    {%- set s2 = (s | replace('\\', '\\\\')) if escape_backslash else s -%}
    {%- set parts = s2.split('\n') -%}
    {%- set out = [] -%}
    {%- for p in parts -%}
        {%- do out.append("'" ~ (p | replace("'", quote_escape)) ~ "'") -%}
    {%- endfor -%}
    {{- return(out | join(' || chr(10) || ')) -}}
{%- endmacro %}


{#- duckdb / ANSI: backslash is a literal character — do NOT escape it; quote doubles as ''. -#}
{% macro default__str_literal(s) -%}
    {{ return(dbt_context_engineering._ce_str_literal(s, false)) }}
{%- endmacro %}

{% macro snowflake__str_literal(s) -%}
    {{ return(dbt_context_engineering._ce_str_literal(s, true)) }}
{%- endmacro %}

{% macro databricks__str_literal(s) -%}
    {{ return(dbt_context_engineering._ce_str_literal(s, true)) }}
{%- endmacro %}

{#- BigQuery: `''` is NOT a valid escaped quote (parsed as adjacent literals) — use `\'`. -#}
{% macro bigquery__str_literal(s) -%}
    {{ return(dbt_context_engineering._ce_str_literal(s, true, "\\'")) }}
{%- endmacro %}
