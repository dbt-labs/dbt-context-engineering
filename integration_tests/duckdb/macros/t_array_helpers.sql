{#- Test-only array helpers, so the chunk assertions can be byte-identical in the duckdb and cloud
    projects (ADR-0015 parity) instead of forking per engine. Ordered array aggregation is already
    dispatched inside the package; these cover only the READ side the tests need.

    Deliberately not in the package itself: consumers never need them, they exist so a test can
    render an array as a comparable scalar. -#}

{#- source_rows -> 'id1,id2,id3'. chunk() already emits the array in unit order, so no sort. -#}
{% macro t_arr_csv(col) -%}
    {%- if target.type == 'databricks' -%}
        array_join({{ col }}, ',')
    {%- else -%}
        array_to_string({{ col }}, ',')
    {%- endif -%}
{%- endmacro %}

{#- does `arr` contain scalar `val`? -#}
{% macro t_arr_has(arr, val) -%}
    {%- if target.type == 'databricks' -%}
        array_contains({{ arr }}, {{ val }})
    {%- elif target.type == 'bigquery' -%}
        {{ val }} in unnest({{ arr }})
    {%- elif target.type == 'snowflake' -%}
        array_contains({{ val }}::variant, {{ arr }})
    {%- else -%}
        list_contains({{ arr }}, {{ val }})
    {%- endif -%}
{%- endmacro %}
