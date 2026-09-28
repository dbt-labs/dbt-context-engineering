{#- Test-only vector literal, so the vector_search and canary calibration fixtures can be
    byte-identical in the duckdb and cloud projects (ADR-0015 parity) instead of forking per
    engine. Every engine spells a fixed-dimension vector literal differently, and the package
    itself never needs one: real callers pass a column or an embed() call.

    Deliberately not in the package. A consumer building a literal vector by hand is doing
    something a fixture does, not something a pipeline does.

    duckdb and BigQuery take a bracketed list, Snowflake needs an explicit VECTOR cast with a
    literal dimension (same constraint canary_cosine_similarity documents), and Databricks has no
    bracket syntax and needs array() with FLOAT elements, since vector_cosine_similarity rejects
    the DOUBLE that unqualified numerics produce. -#}

{% macro t_vec(values) -%}
    {%- set n = values | length -%}
    {%- if target.type == 'databricks' -%}
        array({% for v in values %}cast({{ v }} as float){% if not loop.last %}, {% endif %}{% endfor %})
    {%- elif target.type == 'snowflake' -%}
        [{{ values | join(', ') }}]::vector(float, {{ n }})
    {%- elif target.type == 'bigquery' -%}
        [{{ values | join(', ') }}]
    {%- else -%}
        [{{ values | join(', ') }}]::float[{{ n }}]
    {%- endif -%}
{%- endmacro %}
