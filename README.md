# axRegistry

Canonical registry for the Axis compiler runtime. This repository holds the
`.axreg` source files that define the callable vocabulary available to all
projects consuming the Axis toolchain. Consuming projects pin to a release tag
and fetch via `scripts/fetch-registry.sh`; there are no mutable branch
references in the binding.

## Repository contents

- `axis.axreg` — core compiler primitives: Unit/Bool/Int/Text types, arithmetic,
  comparisons, and value-construction callables. Required by any project that
  compiles Axis surface code.
- `validate.sh` — load-test guard (see Validation below).

## Validation

Before tagging a release, run the load-test guard. It runs the `axis` binary
with a trivial probe source file against each `.axreg` and asserts exit 0
(the registry parses and loads cleanly).

```bash
# From axis-lang root (provides binary + M1 surface configs):
AXIS_LAB=. bash registry-pin/validate.sh
```

Or with an explicit binary path:

```bash
AXIS_LAB=/path/to/axis-lang \
AXIS_BIN=/path/to/target/debug/axis \
bash validate.sh
```

All registries must report `PASS` before tagging.

## Release discipline

1. Update `CHANGELOG.md` (create if absent) with the changes in this release.
2. Run `validate.sh` and confirm all registries pass.
3. Tag: `git tag vX.Y.Z`
4. Push branch and tag: `git push origin main && git push origin vX.Y.Z`
5. Cut a GitHub Release:
   ```bash
   gh release create vX.Y.Z --title "vX.Y.Z" --notes "$(cat CHANGELOG.md)"
   ```
6. Consuming projects bump their `.registry-pin` file to `vX.Y.Z` and re-run
   `scripts/fetch-registry.sh` to pull the new pin.

**Tags are immutable.** Never force-push a tag. If a release is broken, cut a
new patch release.

## Consuming-pin pattern

Consuming projects carry a single `.registry-pin` file containing the pinned
tag string (e.g. `v0.5.0`) and a `scripts/fetch-registry.sh` that clones by
that tag:

```bash
# .registry-pin
v0.5.0
```

```bash
# scripts/fetch-registry.sh
TAG=$(cat "$(git rev-parse --show-toplevel)/.registry-pin")
REPO="https://github.com/christaylor98/axRegistry"
DEST="$(git rev-parse --show-toplevel)/registry-pin"
rm -rf "$DEST"
git clone --branch "$TAG" --depth 1 "$REPO" "$DEST"
echo "Registry pinned at $TAG in $DEST"
```

The pin uses `git clone --branch <tag>` — not `git pull` from a branch.
A tag is an immutable pointer; a branch is not.

## Vocabulary note

Vocabulary is in active development; callable contents will stabilise at v1.0.0.

## The canonical `--reg` set

**There is no `scripts/build.sh`** — not in this repo, not in
`axis-lang`, not in `axis-codegen-bridge-rs`. Documents that refer
to one as the source of truth are wrong. The definition lives in
`CANONICAL_SET` in `validate.sh`, which is machine-readable and is what
`validate.sh` actually loads. Read it from there rather than hardcoding a list.

Order is irrelevant — the loader is flat and resolves the type graph
order-independently.

Counts are deliberately absent from the table below. They were there once —
"411 fns" — and three commits later the file held 459 while the README still
said 411, because nothing checks a number written in prose. What each file
*owns* is the invariant worth stating; how many rows that currently comes to is
a `grep -c '^fn '` away and is always right.

| Member | Declares | Why it is in the set |
|---|---|---|
| `axis-types.axreg` | types only, no fns | Owns the ENTIRE type vocabulary: `Unit Bool Int Text Dec Bytes Float Value ValueList TextList IntList BoolList Fn`. One owner is what makes the set loadable at all. |
| `axis-bridge.axreg` | fns only, no types | Owns the ENTIRE callable vocabulary — **all arithmetic, all comparison, all text ops, and the value/list construction primitives**. This is the real content of the set. |
| `gen-working.axreg` | one fn, no types | `find_from`, a `kind composite` whose body ships as a `.coreir` bundle. Project-local to axAI-axlang-gen-working. |
| `axis.axreg` | nothing | **Contributes nothing.** Retained only so the historical name resolves. See below. |
| `m1-builtins.axreg` | nothing | **Contributes nothing.** See below. |

Both ownership claims are enforced by `validate.sh`, not just asserted here:
it fails if `axis-types.axreg` grows a fn or `axis-bridge.axreg` grows a type.

### Where the primitives actually live

Every arithmetic and text primitive is declared in **`axis-bridge.axreg`**, and
nowhere else:

```
int_add int_sub int_mul int_eq int_lt   ->  axis-bridge.axreg
str_concat str_len str_eq bool_not      ->  axis-bridge.axreg
list_make value_make                    ->  axis-bridge.axreg
```

### Two members are inert, and this is a trap

`axis.axreg` and `m1-builtins.axreg` declare **nothing**:

```
$ axis symbols --reg axis.axreg
$ echo $?
0                                    # exit 0, and zero lines of output
```

Both files are entirely comments. `m1-builtins.axreg`'s comments describe
`value_make`, `list_make`, `value_0/1/2`, `sort`, `filter`, `map` and `reduce`;
it declares none of them. `axis.axreg` carries section headers for
`integer arithmetic` and `text operations` with no entries beneath them. Its
type declarations moved to `axis-types.axreg` when the ownership rule was
enforced.

This has already misled at least one downstream consumer into naming these
files as its vocabulary source. **If you are looking for a callable, it is in
`axis-bridge.axreg`.** Either these two files should declare what their
comments describe, or they should be deleted; leaving them as-is keeps the
trap open.

Note also that `map`, `filter`, `reduce` and `sort` **do not exist** anywhere in
the set. The only `Fn`-taking callables are `all`, `any` and `flat_map`.

## Leaf facts are load-bearing: `effect`, `deterministic`, `idempotent`

These three fields were bulk-imported as defaults when the registry was loaded
with `--no-verify` and nothing read them. That is no longer true. What each one
actually gates today:

| Fact | Read by | If claimed falsely |
|---|---|---|
| `effect pure` **and** `deterministic true`, together | compiler hash-cons (CSE) gate; bridge EFFECT_ORDER_V1 sink; bridge fault classification | two identical calls merge into one; the call is moved into an if-arm past a later effect; a panic becomes a DEFECT (exit 4, never respawned) instead of an Unknown |
| `effect` alone | verifier effect union and `axis verify --effect-ceiling` only | a bundle passes a ceiling it should fail |
| `idempotent` | nothing yet except the cross-file conflict check (two files declaring the same identity with different facts is a hard load error) | dormant; means "safe to re-execute" (retry), not f(f(x)) = f(x) |

Only the pure+deterministic pair changes codegen, and only in the unsafe
direction when over-claimed. Over-declaring (`fullIo`, `deterministic false`)
costs sharing, never correctness.

**A higher-order leaf is coloured by its callback.** `any`, `map`, `fold`, … are
declared `effect pure` because they have no effect of their own. Both the CSE
gate and the bridge treat the *call* as pure only when every fn-ref argument is
itself a pure+deterministic leaf, so `foreach(xs, io_println)` is still
ordered and never merged. That rule is what makes declaring these pure safe.
It is enforced in the bridge from axis-codegen-bridge-rs `call_is_pure_det`
onward; an older bridge reorders effectful callbacks, so do not pair this
registry with one.

**Declaring a leaf pure is a claim about its Rust body.** Read it first: no
thread-local, static, handle table, file, clock, env or socket. Its panics
must be program bugs (overflow, bad shape, out of range), because they will be
reported as defects. `validate.sh` TEST 4 checks the mechanical rules (every
fact explicit; pure => deterministic; pure without callback => idempotent; no
pure leaf in a stateful name family). It cannot check the body.

## Higher-order fns: the `callback` directive (M1_HOF_CALLBACK_CONTRACT_V1)

`Fn` is a single opaque primitive. Every fn-ref reaching Core IR is a constant
pool entry with the *same* `def_hash` — only the 32-byte payload, the target's
minted identity, differs. So `in (ValueList, Fn)` says "some fn-ref" and nothing
more, and the verifier's per-argument type check could not tell one fn-ref from
another. Any callee went into any `Fn` slot: the wrong arity, the wrong argument
types, the wrong return type all verified clean and panicked inside generated
code instead —

```
int_add_vfn: expected a 2-tuple, got Int(3)
flat_map: callee must return ValueList, got Bool(true)
```

Every `Fn` parameter must now carry a `callback` line naming the signature the
fn-ref in that slot must have:

```
fn map
  identity 0x743cd5fc…
  kind     leaf
  in       (ValueList, Fn)
  out      ValueList
  effect   fullIo
  callback 1 (Value) -> Value
end
```

Read it as: *arg 1 is a callback; whatever fn-ref lands there will be applied to
one `Value` and must produce a `Value`.* Several `callback` lines are allowed,
one per `Fn` position — `loop_while` and the `bridge_to_*` dispatchers use two
and three.

**This is required, not optional.** An `Fn` parameter with no `callback` line is
a verification failure at every call site, because an unchecked callback slot is
exactly the defect the directive exists to prevent. Adding a `callback` line
changes no canonical bytes and no identity: contracts live in the scope beside
the projection name table, not in the record stream.

The verifier resolves the fn-ref's payload back to its `FnGenesis` and checks
arity, then arguments, then the return type. It also unions the callee's declared
effect into the call site, so a pure HOF applying a `writes` callback derives
`writes` — a HOF can no longer launder its callback's effect.

### The one thing it cannot check

Argument types are checked contravariantly, with one deliberate relaxation. The
projection has no type variables, so a genuinely parametric HOF —

```
loop_while :: a -> (a -> Bool) -> (a -> a) -> Int -> a
```

— can only erase `a` to the `Value` sum. Real callers pass monomorphic
callbacks (`gr_more(state: Text) -> Bool`), and those are correct: the caller's
own argument fixes `a`. So a callee whose parameter is a constructor payload of
the contract's sum type is admitted. Because that reaches only sum-typed
contract inputs, a contract naming a real type — `Int`, `Text`, `IntList`, the
`Dec`/`Float` arms of `bridge_to_dec` — stays strictly contravariant.

The residual gap: a `Value`-erased slot still admits a callback narrower than
the list it will really be applied to, so `map(int_xs, text_pred)` type-checks.
Closing that needs a type variable in the contract syntax, unified against the
caller's own argument — a change to this projection's grammar, not to the
verifier.

## Ownership (AXREG_LAYERING_VALUE_OWNERSHIP_V1, 2026-09-06)

The `--reg` loader is **flat**: every file passed on one invocation shares a
single type-name → owning-file table, and declaring the same type name in two
files is a hard error — regardless of load order, and regardless of whether
the two declarations are textually identical. There is no precedence,
override, or shadowing mechanism, and none should be added; a name is owned
by exactly one file.

**`axis-types.axreg` owns every type name in the set** — `Unit`, `Bool`,
`Int`, `Text`, `Dec`, `Bytes`, `Float`, `Value`, `ValueList`, `TextList`,
`Fn`. Every other member declares zero types. Enforced by `validate.sh`.

> **Corrected 2026-09-07.** This section previously said `axis.axreg` owned
> the fundamental vocabulary and that siblings "must not redeclare any of the
> above". That was aspirational, not true: `axis.axreg` and
> `axis-bridge.axreg` both declared `Unit`/`Bool`/`Int`/`Text`/`Value`/`Dec`/
> `ValueList`/`Fn`, so the canonical set could not be loaded at all —
> `Registry conflict: duplicate type name 'Unit'`. The rule was written down
> and never checked. `validate.sh` now loads the merged set and asserts zero
> conflicts, so this paragraph cannot rot the same way again.

`Value` is a **closed sum** — `AsUnit(Unit) | AsBool(Bool) | AsInt(Int) |
AsText(Text)`. It exists so bridge fns that are honestly polymorphic over
exactly those four primitives can have that constraint statically checked,
rather than widening to an opaque any-value. Do not add a fifth variant
without checking every caller — the closed set is load-bearing for every fn
declaring `in (Value)` / `out Value`.

> **Corrected 2026-09-07.** This section previously described the closed sum
> under the name `PrimValue`, said to be distinct from an opaque `prim value`
> `Value`, and instructed readers not to rename it. **No type named
> `PrimValue` has ever been declared in this repository** — `axis symbols
> PrimValue` against the canonical set returns nothing, and it appears in no
> `.axreg`. The closed sum has always been called `Value`. The opaque
> `prim value` variant it was contrasted against was `axis.axreg`'s
> now-removed declaration (`212f4f49…`), which no fn ever referenced.
