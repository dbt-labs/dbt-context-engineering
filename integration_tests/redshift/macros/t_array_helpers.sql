{#- Test-only array helpers, so the chunk assertions can be byte-identical in the duckdb and cloud
    projects (ADR-0015 parity) instead of forking per engine. Ordered array aggregation is already
    dispatched inside the package; these cover only the READ side the tests need.

    Deliberately not in the package itself: consumers never need them, they exist so a test can
    render an array as a comparable scalar. -#}

{#- source_rows -> 'id1,id2,id3'. chunk() already emits the array in unit order, so no sort. -#}
{% macro t_arr_csv(col) -%}
    {%- if target.type == 'databricks' -%}
        array_join({{ col }}, ',')
    {%- elif target.type == 'redshift' -%}
        {#- source_rows is a SUPER array of JSON-string ids (package array_agg builds it via
            json_parse of a listagg). Serialize back to '["a","b"]' and strip the JSON array syntax
            to 'a,b'. Fine for test ids (no commas/brackets inside an id). -#}
        replace(replace(replace(json_serialize({{ col }}), '"', ''), '[', ''), ']', '')
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
    {%- elif target.type == 'redshift' -%}
        {#- SUPER array of quoted JSON-string ids: look for the quoted id in the serialized array.
            The surrounding quotes prevent a prefix false-match ("e1" won't match inside "e12"). -#}
        position('"' || cast({{ val }} as varchar) || '"' in json_serialize({{ arr }})) > 0
    {%- else -%}
        list_contains({{ arr }}, {{ val }})
    {%- endif -%}
{%- endmacro %}
