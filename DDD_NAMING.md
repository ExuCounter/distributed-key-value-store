# Naming conventions

This document fixes the vocabulary used across the codebase. The goal is that every
function signature, variable name, and ETS table layout uses these terms with the
same meaning. If a concept does not appear here, do not invent a synonym -> extend
this document instead.

## Core terms

### Entity
An **entity** is a named collection of records of the same shape. It is the
domain-level "table" or "type" — for example `:user`, `:order`, `:account`.

- Always an atom.
- Variable name: `entity`. Never `type`, `table`, `kind`, `collection`, `model`.
- An entity has exactly one schema registered via `DS.Storage.Schema.register/2`.

### Schema
A **schema** describes the fields of an entity and their types. It is a map
`%{field => field_spec}`.

- Variable name: `schema`.
- Looked up by entity.

### Field
A **field** is a named attribute defined by a schema. It is the column-level
concept inside an entity.

- Always an atom.
- Variable name: `field`. Never `column`, `attribute`, `prop`, `name`.

### Key
A **key** uniquely identifies one record within an entity. In the primary store
the physical ETS key is the tuple `{entity, key}`; the bare `key` term refers to
the per-entity identifier only.

- Variable name: `key`. Never `id`, `pk`, `uid`, `identifier`.
- When the full composite is meant, name it `primary_key` and shape it
  `{entity, key}`.

### Record
A **record** is the full map of field-to-value pairs stored against a single key.
It is the row-level value.

- Variable name: `record`. Never `value`, `value_map`, `row`, `doc`, `data`, `obj`.
- The shape stored in `:primary` is `{{entity, key}, record, clock}`.
- Canonical record shape: `%{field => {type, value, clock}}`. Each field carries
  its CRDT `type` (`:lww`, `:counter`, `:set`), its current `value`, and a
  per-field vector `clock`. `DS.CRDT.resolve_conflict/3` operates on the
  `{value, clock}` pair per field; the outer clock in `:primary` is a
  record-level write counter.

### Value
A **value** is the content of a single field within a record. It is what you get
from `Map.get(record, field)`.

- Variable name: `value`. Never `field_value`, `val`, `v`.
- In index tables values are the index key; records are looked up by `key`.

### Clock
A **clock** is a vector clock map `%{node => counter}` attached to a record. It
is never split or renamed at call sites.

- Variable name: `clock`. Never `vc`, `version`, `ts`.

### Node
A **node** is an Erlang node atom. Used in routing, replication, and clocks.

- Variable name: `node`.

### Slot
A **slot** is an integer in `0..@slots-1` produced by hashing a key. Slots map
to nodes via `DS.Routing`.

- Variable name: `slot`.

## Canonical shapes

| Where                  | Shape                                              |
|------------------------|----------------------------------------------------|
| `:primary` row         | `{{entity, key}, record, clock}`                   |
| `:indexes` row         | `{{entity, field}, index_name}`                    |
| forward index row      | `{value, key}` in `:"index_<entity>_<field>"`      |
| reverse index row      | `{key, value}` in `:"rindex_<entity>_<field>"`     |
| `:schemas` row         | `{entity, schema}`                                 |
| `:routing` row         | `{slot, node}`                                     |

## Function signature rules

Argument order is always: `entity, key, field, value, record, clock, node`,
dropping the ones a function does not need but preserving the relative order.

Examples of correct signatures:

```elixir
DS.Storage.Primary.get(primary_key)                          # primary_key = {entity, key}
DS.Storage.Primary.put(primary_key, record, clock)
DS.Storage.Index.update_index(entity, field, key, value)
DS.Storage.Index.indexed_value(entity, field, key)           # returns {:ok, value}
DS.Storage.Schema.get_field(entity, field)
DS.Router.which_node(key)
```
