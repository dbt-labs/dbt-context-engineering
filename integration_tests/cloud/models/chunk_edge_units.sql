{{ config(materialized='table') }}

{#- Unit fixture for chunk()'s data-shape edge cases. Char counts are exact multiples of 4 so
    ceil(chars/4) lands on the intended token count with no rounding slack.

      adr_ex      18/17/25/30-token units, the worked example in ADR-0002. Pins the packing
                  semantics the implementation actually has (a unit that crosses a boundary joins
                  the CURRENT chunk) against the lookahead packing that ADR's diagram depicts.
      oversize    one 400-token unit against a 40-token budget. Units are never split, so the
                  overshoot is bounded only by the largest unit, not by "one small unit".
      single      a partition with exactly one unit.
      null_mid    a NULL text unit between two real ones.
      empty_mid   an empty-string text unit in the same position, for contrast with null_mid.
      all_null    every unit's text is NULL.
-#}

select 'e1' as unit_id, 1 as turn_index, 'adr_ex' as pk, repeat('a', 72) as unit_text, 'S' as speaker
union all select 'e2', 2, 'adr_ex',    repeat('b', 68),   'S'
union all select 'e3', 3, 'adr_ex',    repeat('c', 100),  'S'
union all select 'e4', 4, 'adr_ex',    repeat('d', 48),   'S'
union all select 'e5', 5, 'adr_ex',    repeat('e', 120),  'S'

union all select 'o1', 1, 'oversize',  repeat('f', 16),   'S'
union all select 'o2', 2, 'oversize',  repeat('g', 1600), 'S'
union all select 'o3', 3, 'oversize',  repeat('h', 16),   'S'

union all select 'i1', 1, 'single',    repeat('i', 40),   'S'

union all select 'n1', 1, 'null_mid',  repeat('j', 40),   'S'
union all select 'n2', 2, 'null_mid',  cast(null as {{ dbt.type_string() }}), 'S'
union all select 'n3', 3, 'null_mid',  repeat('k', 40),   'S'

union all select 'm1', 1, 'empty_mid', repeat('l', 40),   'S'
union all select 'm2', 2, 'empty_mid', '',                'S'
union all select 'm3', 3, 'empty_mid', repeat('m', 40),   'S'

union all select 'z1', 1, 'all_null',  cast(null as {{ dbt.type_string() }}), 'S'
union all select 'z2', 2, 'all_null',  cast(null as {{ dbt.type_string() }}), 'S'
