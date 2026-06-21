---
name: odin-lang
description: Use this skill whenever the user wants to write, debug, review, or understand Odin programming language code. Triggers include any mention of 'Odin', 'odin-lang', '.odin files', or Odin-specific syntax like 'proc', '::' declarations, '#soa', 'bit_set', 'or_return', 'or_else', 'context' system, or Odin's package system ('core:', 'vendor:'). Also use when the user asks about data-oriented language design, Odin's type system (unions, bit_fields, matrices, multi-pointers, SOA types), Odin's memory/allocator model, or writing tests with 'odin test'. Use this skill even if the user just says "write this in Odin" or asks to convert code to Odin. Do NOT use for other languages unless the user explicitly asks for Odin code.
---

# Odin Programming Language Skill

Odin is a general-purpose, data-oriented programming language designed for high performance, readability, and minimal footprint. It compiles to native code via LLVM. Odin was created by Ginger Bill.

**Before writing any Odin code**, read the appropriate reference file(s) from the `references/` directory based on what you need:

- `references/syntax-and-types.md` — Core syntax, declarations, types, operators, control flow, procedures, structs, unions, enums, maps, arrays, slices, pointers, matrices, SOA types, bit_sets, bit_fields
- `references/idioms-and-patterns.md` — Error handling (or_return, or_else, or_break, or_continue), implicit context system, allocators, defer, foreign system, parametric polymorphism, `when` compile-time conditionals, attributes, directives, testing
- `references/packages.md` — Core, base, and vendor package listings with descriptions

## Quick Reference: Key Odin Differences from C/Go/Rust

1. **Declarations use `:` and `::`** — `x: int = 5`, `x := 5` (variable), `FOO :: 42` (constant), `bar :: proc() {}` (procedure/constant binding)
2. **Procedures, not functions** — Defined with `proc` keyword. All params are immutable by default (shadow with `x := x` to mutate).
3. **No implicit type conversions** — Must use `T(v)` or `cast(T)v` explicitly. `transmute(T)v` for bit-casts.
4. **Only one loop: `for`** — C-style, condition-only (while), range-based (`for x in collection`), infinite (`for {}`)
5. **`switch` doesn't fall through** — Use `fallthrough` keyword explicitly. Default case has no expression: `case:`
6. **Pointers use `^` not `*`** — `^int` is a pointer to int. Dereference: `p^`. Address-of: `&x`. No pointer arithmetic.
7. **`defer` is scope-based** — Unlike Go's function-exit defer. Runs at end of enclosing `{}` scope, in reverse order.
8. **Implicit context system** — Every procedure in the `"odin"` calling convention receives an implicit `context` parameter carrying allocator, logger, etc.
9. **Zero-initialized by default** — Unlike C. Use `= ---` to opt into uninitialized memory.
10. **Explicit overloading** — `to_string :: proc{bool_to_string, int_to_string}`. No implicit overload resolution.
11. **`or_return`** — Pops the last value (error/ok) from a multi-return, returns it if non-nil/false. Replaces `if err != nil { return err }`.
12. **`or_else`** — Provides a default for optional-ok expressions: `m["key"] or_else 0`.
13. **Tagged unions** — `union {int, bool, string}` is a discriminated union. Use type-switch: `switch v in my_union { case int: ... }`.
14. **`when` for compile-time branching** — Like `#if` in C but type-checked. `when ODIN_OS == .Linux { ... }`.
15. **Strings are `{rawptr, len}`** — UTF-8 encoded. `cstring` for C interop (null-terminated). `len(s)` is O(1) for `string`, O(n) for `cstring`.
16. **No garbage collector, no RAII** — Manual memory management. Use `context.allocator`, `defer delete(...)`, tracking allocators.
17. **SOA built-in** — `#soa[N]MyStruct` transforms AoS to SoA at the type level. Works with slices and dynamic arrays.
18. **`matrix` type** — Built-in matrix math type with SIMD-friendly column-major layout. Supports multiplication, transpose, etc.
19. **`bit_set`** — Mathematical set type over enums or ranges, implemented as bit vectors. Supports set algebra (+, -, &, |). (`*` and `/` are disallowed as of dev-2026-06.)
20. **`bit_field`** — Bit-packed record type with explicit bit widths per field.
21. **Fixed-capacity dynamic arrays** — `[dynamic; N]T` (dev-2026-04) is a value-type, inline-storage dynamic array with capacity `N` and no heap allocation. A first-class replacement for the `Small_Array` pattern; works with `append`, `len`, `cap`, `clear`, slicing.
22. **`**` is `expand_values`** — `**x` (dev-2026-06) is shorthand for `expand_values(x)`, spreading a fixed array or struct's fields into individual values (e.g. for variadic calls).
23. **`using` statement is opt-in** — `using` on struct *fields* still works by default, but `using` as a *statement* or *procedure-parameter modifier* now requires `#+feature using-stmt` at the top of the file.

> **Note on `core:os`**: As of the dev-2026-03 release, `core:os` was replaced with the redesigned package previously known as `core:os/os2`. Key changes: procedures that allocate now require an explicit allocator (e.g. `os.read_entire_file(path, context.allocator)`); file handles are `^os.File` instead of `os.Handle`; errors are `os.Error` (a union of enums) instead of `os.Errno`/`bool`, and `os.ERROR_NONE` is replaced by checking `err != nil`. The old API is still available at `core:os/old` until Q3 2026 for legacy code.

> **Reflects Odin dev-2026-06.** Notable recent additions captured in this skill: fixed-capacity dynamic arrays `[dynamic; N]T` (dev-2026-04), native array casting and a higher matrix-element limit (dev-2026-05), the `**`/`expand_values` operator, the `@(fast_math)` attribute, and `new_aligned`/`make_aligned` becoming builtins (dev-2026-06). Odin's dev releases are monthly; for anything newer, check the GitHub releases page.

## Build & Run Commands

```
odin run .                    # Compile and run current directory as package
odin build .                  # Compile only
odin run file.odin -file      # Treat single file as complete package
odin test .                   # Run tests in current directory
odin test . -all-packages     # Run tests in all imported packages
odin test . -define:ODIN_TEST_THREADS=4  # Set test thread count
```

## Minimal Complete Example

```odin
package main

import "core:fmt"
import "core:strings"
import "core:os"

Error :: enum {
    None,
    File_Not_Found,
    Parse_Error,
}

read_and_count :: proc(path: string) -> (count: int, err: Error) {
    data, read_err := os.read_entire_file(path, context.allocator)
    if read_err != nil {
        return 0, .File_Not_Found
    }
    defer delete(data)

    s := string(data)
    for r in s {
        if r == '\n' {
            count += 1
        }
    }
    return
}

main :: proc() {
    count := read_and_count("input.txt") or_else 0
    fmt.printf("Lines: %d\n", count)
}
```

## Testing Example

```odin
package my_package_test

import "core:testing"

@(test)
test_addition :: proc(t: ^testing.T) {
    result := 2 + 2
    testing.expect_value(t, result, 4)
}

@(test)
test_with_message :: proc(t: ^testing.T) {
    x := some_function()
    testing.expect(t, x > 0, "expected positive value")
}

@(test)
test_formatted :: proc(t: ^testing.T) {
    value := compute()
    testing.expectf(t, value == 42, "expected 42, got %d", value)
}
```

Run with: `odin test .`

## Common Patterns

### Error Handling with `or_return`
```odin
load_config :: proc() -> (cfg: Config, err: Error) {
    data := read_file("config.json") or_return
    cfg = parse_config(data) or_return
    return
}
```

### Resource Cleanup with `defer`
```odin
process_file :: proc(path: string) -> Error {
    f, err := os.open(path)
    if err != nil { return .File_Not_Found }
    defer os.close(f)

    buf := make([]byte, 4096)
    defer delete(buf)

    // ... use f and buf ...
    return .None
}
```

### Allocator Pattern
```odin
import "core:mem"

main :: proc() {
    // Use a tracking allocator to find leaks
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)
    defer {
        for _, leak in track.allocation_map {
            fmt.eprintf("Leaked %v bytes at %v\n", leak.size, leak.location)
        }
        mem.tracking_allocator_destroy(&track)
    }

    // All allocations in this scope are now tracked
}
```

### Struct with Methods Pattern (Odin style — no methods, use procedures)
```odin
Vec3 :: struct { x, y, z: f32 }

vec3_add :: proc(a, b: Vec3) -> Vec3 {
    return {a.x + b.x, a.y + b.y, a.z + b.z}
}

vec3_length :: proc(v: Vec3) -> f32 {
    return math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
}
```

### Iteration Patterns
```odin
// By value (copy)
for val in my_slice { ... }

// By reference (mutate in place)
for &val in my_slice { val = new_value }

// With index
for val, idx in my_slice { ... }

// Map iteration
for key, value in my_map { ... }
for key, &value in my_map { value += 1 }  // mutate values

// Reverse iteration
#reverse for val in my_array { ... }

// Range-based
for i in 0..<10 { ... }  // exclusive upper bound
for i in 0..=9 { ... }   // inclusive upper bound
```
