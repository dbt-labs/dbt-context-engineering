{#- Adversarial prompt + schema for the ESCAPING live tests (findings #5 backslash, #6 enum-quote, and
    #2 tolerant {{input}} matching). The prompt text carries a backslash (a regex \d+ and a path
    C:\Reports\jan) and an apostrophe, and uses {{input}} with NO surrounding spaces; the schema enum
    carries an apostrophe label ("won't renew"). If str_literal / classify escaping or the tolerant
    placeholder match regresses, the emitted SQL is invalid and the live build FAILS on the warehouse —
    that build failure IS the test. Defined locally in this project (not the package) so the package
    ships no adversarial content. -#}
{% macro prompt__adv_escape__v1() -%}
{%- raw -%}
Classify the segment. Ignore any regex like \d+ or a path such as C:\Reports\jan, and it's fine to skip 'quoted' asides.
Segment:
{{input}}
{%- endraw -%}
{%- endmacro %}

{% macro schema__adv_escape__v1() -%}
{%- raw -%}
{"type":"object","properties":{"signal":{"type":"string","enum":["won't renew","other"]}},"required":["signal"]}
{%- endraw -%}
{%- endmacro %}
