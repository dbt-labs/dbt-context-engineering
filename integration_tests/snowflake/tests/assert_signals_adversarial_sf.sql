-- LIVE escaping (#5/#6/#2): signals_adversarial_sf builds only if the escaped prompt literal and the
-- escaped enum array are valid SQL on this warehouse. Every classified label must be one of the
-- (logical) enum values — including the apostrophe-bearing one round-tripping intact. Fail rows only.
select 'bad_label' as issue
from {{ ref('signals_adversarial_sf') }}
where signal is null or signal not in ('won''t renew', 'other')
