-- LIVE escaping (#5/#6/#2): signals_adversarial builds only if the escaped prompt literal and the
-- escaped enum array are valid SQL on this warehouse. Every classified label must be one of the
-- (logical) enum values — including the apostrophe-bearing one round-tripping intact. Fail rows only.
-- NOTE: the apostrophe label is written with BigQuery's DOUBLE-quoted string form ("won't renew");
-- the ANSI doubled-quote ('won''t renew') is invalid on BigQuery (parsed as adjacent literals).
select 'bad_label' as issue
from {{ ref('signals_adversarial') }}
{% if target.type == 'bigquery' %}
where signal is null or signal not in ("won't renew", "other")
{% else %}
where signal is null or signal not in ('won''t renew', 'other')
{% endif %}
