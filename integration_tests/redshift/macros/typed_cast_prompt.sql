{#-
  Prompt + schema for the typed-cast probe (hub #178). The schema has one integer, one number and
  one boolean field, and the prompt pins their values, so the cast result is checkable without
  judging model quality. Defined locally in the project for the same Fusion reason as
  example_signal_classify_prompt.sql.
-#}

{% macro prompt__EXAMPLE_typed_cast__v1() -%}
{%- raw -%}
Ignore the meaning of the segment below. Return all three fields, never omit one:
count = 7, ratio = 0.25, flag = true (the boolean value true).

Segment:
{{ input }}
{%- endraw -%}
{%- endmacro %}


{% macro schema__EXAMPLE_typed_cast__v1() -%}
{%- raw -%}
{
  "type": "object",
  "properties": {
    "count": {"type": "integer"},
    "ratio": {"type": "number"},
    "flag": {"type": "boolean"}
  },
  "required": ["count", "ratio", "flag"],
  "additionalProperties": false
}
{%- endraw -%}
{%- endmacro %}
