-- chunk_fn_fingerprint must change when any output-affecting argument changes.
-- Returns rows only on collision, naming the argument the fingerprint ignored. Pure compile-time
-- assertion: it compares fingerprints for different argument sets in Jinja, so it needs no
-- warehouse data and no second dbt run.
--
-- Why this matters: chunk()'s partition hash is taken over its INPUT units, so a pure config
-- change leaves every input byte identical while completely re-cutting the output. The
-- fingerprint is folded into that hash to make the change detectable. If any argument silently
-- fell out of the fingerprint, an incremental chunk model would keep serving output built under
-- the previous configuration while reporting success, which is the exact failure this pins.

{% set base = {
    'target_tokens': 40, 'overlap_tokens': 0, 'join_separator': '\n',
    'id_column': 'unit_id', 'order_column': 'turn_index', 'text_column': 'unit_text',
    'partition_column': 'pk', 'label_column': none
} %}

{% set variants = {
    'target_tokens':    dict(base, **{'target_tokens': 41}),
    'overlap_tokens':   dict(base, **{'overlap_tokens': 5}),
    'join_separator':   dict(base, **{'join_separator': ' '}),
    'id_column':        dict(base, **{'id_column': 'other_id'}),
    'order_column':     dict(base, **{'order_column': 'other_order'}),
    'text_column':      dict(base, **{'text_column': 'other_text'}),
    'partition_column': dict(base, **{'partition_column': 'other_pk'}),
    'label_column':     dict(base, **{'label_column': 'speaker'})
} %}

{% set base_fp = dbt_context_engineering.chunk_fn_fingerprint(**base) %}

{% set collisions = [] %}
{% for arg_name, variant in variants.items() %}
    {% if dbt_context_engineering.chunk_fn_fingerprint(**variant) == base_fp %}
        {% do collisions.append(arg_name) %}
    {% endif %}
{% endfor %}

{% if collisions | length == 0 %}
select cast(null as {{ dbt.type_string() }}) as ignored_argument limit 0
{% else %}
{% for arg_name in collisions %}
{% if not loop.first %}union all {% endif %}select '{{ arg_name }}' as ignored_argument
{% endfor %}
{% endif %}
