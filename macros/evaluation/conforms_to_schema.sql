{#-
  conforms_to_schema(relation, column, schema_name, schema_version, property=none,
  allow_null=false) -> a SELECT of the rows whose `column` value is NOT in the enum declared by
  the named schema. Empty result = all rows conform. Catches an LLM that invents a label
  outside the taxonomy.

  Used in a SINGULAR test (tests/*.sql), e.g.:
      {{ dbt_context_engineering.conforms_to_schema(ref('signals'), 'signal',
                                                       'EXAMPLE_signal_classify', 'v3') }}

  Why a singular-test macro and not a schema.yml generic test: resolving a versioned schema macro
  by name needs the dynamic namespace subscript of schema (D4), which is only available in
  model/singular-test render context — dbt's generic-test capture render cannot do it. Singular
  tests render like models, so the schema resolves and the allowed set stays single-sourced from
  schema (never a hand-copied list that can drift). Deterministic — no warehouse, no AI.
-#}
{% macro conforms_to_schema(relation, column, schema_name, schema_version,
                               property=none, allow_null=false) -%}
{%- set enum = dbt_context_engineering.schema_enum(
        dbt_context_engineering.schema_def(schema_name, schema_version), property) -%}
select {{ column }} as _value
from {{ relation }}
where {{ column }} not in (
    {%- for v in enum -%}'{{ v | replace("'", "''") }}'{%- if not loop.last -%}, {% endif -%}{%- endfor -%}
)
{% if not allow_null %}or {{ column }} is null{% endif %}
{%- endmacro %}
