{#-
  ce_schema_enum(output_schema, property=none) -> the list of allowed values (the enum) declared
  by an output schema, resolved at compile time. If `property` is given, that property's enum is
  returned; otherwise the first enum-bearing property is used (the taxonomy label set).

  Single-sources the label set from the same ce_schema macro the wrappers use (prompts-are-code):
  the eval/conformance tests check against exactly the enum the model was told to produce.
-#}
{% macro ce_schema_enum(output_schema, property=none) -%}
    {%- set sd = fromjson(output_schema) -%}
    {%- set props = sd.get('properties', {}) -%}
    {%- if property is not none -%}
        {%- set pdef = props.get(property) -%}
        {%- if pdef is none or not pdef.get('enum') -%}
            {{ exceptions.raise_compiler_error(
                "ce_schema_enum: property '" ~ property ~ "' is absent or has no enum.") }}
        {%- endif -%}
        {{- return(pdef.get('enum')) -}}
    {%- endif -%}
    {%- set ns = namespace(found=none) -%}
    {%- for pname, pdef in props.items() -%}
        {%- if ns.found is none and pdef.get('enum') -%}
            {%- set ns.found = pdef.get('enum') -%}
        {%- endif -%}
    {%- endfor -%}
    {%- if ns.found is none -%}
        {{ exceptions.raise_compiler_error("ce_schema_enum: schema has no enum property.") }}
    {%- endif -%}
    {{- return(ns.found) -}}
{%- endmacro %}
