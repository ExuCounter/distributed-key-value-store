# ADR 0018: Naming Conventions

- Status: Accepted
- Date: 2026-06-18
- Deciders: DS project
- Component: codebase-wide

## Context

A distributed key-value store has many overlapping terms with subtly
different meanings: row, record, value, document; key, id, identifier;
column, field, attribute; clock, version, timestamp. Different files
drifting toward different vocabularies makes the codebase harder to read
and easier to break. A function called `update(table, id, fields)` and
another called `put(entity, key, record)` look unrelated until you
realize they do the same thing.

We need a fixed vocabulary so that every function signature, variable
name, and ETS table layout uses the same terms with the same meaning.
The vocabulary also fixes function-argument order, so signatures across
modules read consistently.

## Decision

The following terms are the canonical vocabulary. If a concept does not
appear here, do not invent a synonym — extend this ADR instead.

### Entity

A named collection of records of the same shape. The domain-level
"table" or "type" — for example `:user`, `:order`, `:account`.

- Always an atom.
- Variable name: `entity`. Never `type`, `table`, `kind`, `collection`,
  `model`.
- An entity has exactly one schema registered via
  `DS.Storage.Schema.register/2`.

### Schema

A map `%{field => field_spec}` describing the fields of an entity and
their CRDT types.

- Variable name: `schema`.
- Looked up by entity.

### Field

A named attribute defined by a schema. The column-level concept inside
an entity.

- Always an atom.
- Variable name: `field`. Never `column`, `attribute`, `prop`, `name`.

### Key

The per-entity identifier of a single record. In the primary store the
physical ETS key is the tuple `{entity, key}`; the bare `key` term refers
to the per-entity identifier only.

- Variable name: `key`. Never `id`, `pk`, `uid`, `identifier`.
- When the full composite is meant, name it `primary_key` and shape it
  `{entity, key}`.

### Record

The full map of field-to-value pairs stored against a single key. The
row-level value.

- Variable name: `record`. Never `value`, `value_map`, `row`, `doc`,
  `data`, `obj`.
- The shape stored in `:primary` is `{{entity, key}, record, clock}`.
- Canonical record shape: `%{field => {type, value, clock}}`. Each field
  carries its CRDT `type` (`:lww`, `:counter`, `:set`), its current
  `value`, and a per-field vector `clock`. `DS.CRDT.resolve_conflict/3`
  operates on the `{value, clock}` pair per field; the outer clock in
  `:primary` is a record-level write counter.

### Value

The content of a single field within a record. What you get from
`Map.get(record, field)`.

- Variable name: `value`. Never `field_value`, `val`, `v`.
- In index tables, values are the index key; records are looked up by
  `key`.

### Clock

A vector clock map `%{node => counter}` attached to a record. Never
split or renamed at call sites.

- Variable name: `clock`. Never `vc`, `version`, `ts`.

### Node

An Erlang node atom. Used in routing, replication, and clocks.

- Variable name: `node`.

### Slot

An integer in `0..@slots-1` produced by hashing a key. Slots map to
nodes via `DS.Routing`.

- Variable name: `slot`.

## Canonical shapes

| Where                  | Shape                                              |
|------------------------|----------------------------------------------------|
| `:primary` row         | `{{entity, key}, record, clock}`                   |
| `:indexes` row         | `{{entity, field}, index_name}`                    |
| forward index row      | `{{value, key}, key}` in `:"index_<entity>_<field>"`|
| reverse index row      | `{key, value}` in `:"rindex_<entity>_<field>"`     |
| `:schemas` row         | `{entity, schema}`                                 |
| `:routing` row         | `{slot, node}`                                     |

## Function signature rules

Argument order is always: `entity, key, field, value, record, clock,
node`, dropping the ones a function does not need but preserving the
relative order.

Examples of correct signatures:

```elixir
DS.Storage.Primary.get(primary_key)                          # primary_key = {entity, key}
DS.Storage.Primary.put(primary_key, record, clock)
DS.Storage.Index.update_index(entity, field, key, value)
DS.Storage.Index.indexed_value(entity, field, key)           # returns {:ok, value}
DS.Storage.Schema.get_field(entity, field)
DS.Router.which_node(key)
```

## Style rules derived from the vocabulary

- **No abbreviated identifiers.** Spell domain names out: `clock` not
  `clk`, `record` not `rec`, `accumulator` not `acc`. Loop variables
  `i`/`n` are fine in pure numeric contexts.
- **No synonyms.** If a function operates on a record, the parameter is
  named `record`, not `r` or `row` or `obj` — even if the receiving
  function is short and "obvious".

## Consequences

### Positive

- Reading any function signature, you know what each argument is from
  its name alone.
- Cross-module refactors are mechanical: renaming `entity` to `tenant`
  (hypothetically) is a single grep, not a guess-and-test exercise.
- New contributors have a single document to read for vocabulary.

### Negative

- Some signatures get long when several positional terms are involved.
  The trade-off is consciously accepted: readability over brevity.
- Adding a new domain concept requires updating this ADR before it
  appears in code, which is mild friction. Intentional — keeps the
  vocabulary stable.

## Alternatives considered

1. **Let module authors choose names per module.** Rejected. Produced
   the very inconsistency this ADR fixes.
2. **Use short names (`k`, `v`, `clk`) inside private functions, full
   names at module boundaries.** Rejected. Short names inside private
   functions inevitably leak into log messages, error tuples, and
   public-facing arguments through copy-paste. Pick one rule, apply
   everywhere.

## Related

- ADR-0001 — Index entry storage. Uses the canonical shapes defined
  here.
