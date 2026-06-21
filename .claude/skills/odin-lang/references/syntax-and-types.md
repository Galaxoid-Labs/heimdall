# Odin Syntax and Types Reference

## Table of Contents
1. [Declarations](#declarations)
2. [Basic Types](#basic-types)
3. [Strings](#strings)
4. [Control Flow](#control-flow)
5. [Procedures](#procedures)
6. [Arrays and Slices](#arrays-and-slices)
7. [Dynamic Arrays](#dynamic-arrays)
8. [Maps](#maps)
9. [Structs](#structs)
10. [Enums](#enums)
11. [Unions](#unions)
12. [Pointers and Multi-Pointers](#pointers-and-multi-pointers)
13. [Bit Sets](#bit-sets)
14. [Bit Fields](#bit-fields)
15. [Matrices](#matrices)
16. [SOA Types](#soa-types)
17. [Operators](#operators)
18. [Type Conversions](#type-conversions)

---

## Declarations

```odin
// Variables
x: int                    // zero-initialized
x: int = 123              // explicit type + value
x := 123                  // type-inferred (shorthand for x: int = 123)
x, y := 1, "hello"        // multiple
x: int = ---              // explicitly uninitialized

// Constants (must be compile-time evaluable)
FOO :: 42                  // untyped integer constant
BAR : int : 42             // typed constant
BAZ :: FOO + 7             // computed constant

// Type aliases and distinct types
My_Int :: int              // alias (My_Int == int)
My_Int :: distinct int     // distinct (My_Int != int)

// Procedure declarations (procedures are constants)
foo :: proc() { }
bar :: proc(x: int) -> int { return x * 2 }
```

**`:=` is two tokens**: `:` (declare) and `=` (assign). These are equivalent:
```odin
x: int = 123
x:     = 123    // type inferred from literal
x := 123        // shorthand
```

---

## Basic Types

```
// Booleans
bool b8 b16 b32 b64

// Signed integers
int i8 i16 i32 i64 i128

// Unsigned integers
uint u8 u16 u32 u64 u128 uintptr

// Endian-specific integers
i16le i32le i64le i128le u16le u32le u64le u128le
i16be i32be i64be i128be u16be u32be u64be u128be

// Floats
f16 f32 f64
f16le f32le f64le   // little endian
f16be f32be f64be   // big endian

// Complex & quaternion
complex32 complex64 complex128
quaternion64 quaternion128 quaternion256

// Other
rune       // signed 32-bit, Unicode code point (distinct from i32)
string     // {rawptr, len} — UTF-8
cstring    // null-terminated C string
rawptr     // raw pointer (like void*)
typeid     // runtime type identifier
any        // {rawptr, typeid}
```

**Default int/uint** are register-sized (≥ pointer size). Use `int` unless you need a specific size.

### Zero Values
- `0` for numerics and rune
- `false` for booleans
- `""` for strings
- `nil` for pointers, typeid, any, procedure types, maps, slices, dynamic arrays

### Untyped Constants
```odin
I :: 42        // untyped integer — converts to any numeric type
F :: 1.37      // untyped float — converts to any float type
S :: "hello"   // untyped string — converts to string or cstring
B :: true      // untyped boolean
```

---

## Strings

`string` = `{rawptr, len}`. Immutable. UTF-8. `len(s)` is O(1).
`cstring` = null-terminated C string. `len(cs)` is O(n).

```odin
s := "hello"                // string literal
r := `raw\string`           // raw string (backtick)
c: cstring = "hello"        // cstring from literal (no alloc)
s2 := string(c)             // cstring → string (O(n) scan for null)
```

### String Conversions (copy vs alias)
| From → To       | Copy                                  | Alias (no alloc)                          |
|------------------|---------------------------------------|-------------------------------------------|
| string → []u8    |                                       | `transmute([]u8)st`                       |
| string → string  | `strings.clone(st)`                   |                                           |
| string → cstring | `strings.clone_to_cstring(st)`        | `strings.unsafe_string_to_cstring(st)`    |
| cstring → string |                                       | `string(st)`                              |
| []u8 → string    |                                       | `string(st)` or `transmute(string)st`     |

### String Iteration
```odin
// By runes (UTF-8 decode) — preferred
for ch in my_string { /* ch is rune */ }
for ch, idx in my_string { /* idx is byte offset */ }

// By bytes
for i in 0..<len(my_string) { my_string[i] /* u8 */ }
```

---

## Control Flow

### For Loop (only loop construct)
```odin
// C-style
for i := 0; i < 10; i += 1 { }

// Condition-only (while)
for condition { }

// Infinite
for { }

// Range-based
for i in 0..<10 { }       // half-open [0,10)
for i in 0..=9 { }        // closed [0,9]

// Collection iteration
for val in my_slice { }
for val, idx in my_slice { }
for &val in my_slice { val = new_val }  // by-reference
for key, value in my_map { }
for key, &value in my_map { value += 1 }

// Reverse
#reverse for val in my_array { }

// Unroll (compile-time, constant range only)
#unroll for i in 0..<4 { }
```

### If Statement
```odin
if x > 0 { }
if x := foo(); x > 0 { }  // with init statement
if x > 0 { } else if x == 0 { } else { }
```

### Switch Statement
```odin
switch val {
case 1: foo()
case 2, 3: bar()
case 4..<10: baz()
case: default_case()       // default = no expression
}

// No implicit fallthrough. Use `fallthrough` keyword explicitly.
switch val {
case 0:
    foo()
    fallthrough
case 1:
    bar()  // runs for both 0 and 1
}

// Without condition (== switch true)
switch {
case x < 0: neg()
case x > 0: pos()
case: zero()
}

// Partial switch on enums (no exhaustiveness check)
#partial switch my_enum_val {
case .A: ...
case .B: ...
}
```

### When Statement (compile-time if)
```odin
when ODIN_OS == .Windows {
    // Windows-only code
} else when ODIN_OS == .Linux {
    // Linux-only code
} else {
    // Fallback
}
```
- Conditions must be compile-time constants
- Does NOT create a new scope
- Only the true branch is semantically checked
- Allowed at file scope

### Defer
```odin
{
    f := open_file()
    defer close_file(f)    // runs at end of this scope
    // ... use f ...
}  // close_file(f) called here

// Reverse order
defer fmt.println("1")
defer fmt.println("2")
// prints: 2, then 1

// Defer a block
defer {
    cleanup_a()
    cleanup_b()
}
```

### Branch Statements
```odin
break                   // break innermost for/switch
break my_label          // break labeled construct
continue                // next iteration
continue my_label       // next iteration of labeled loop
fallthrough             // explicit fallthrough in switch

// Labeled blocks
exit: {
    if condition { break exit }
    // skipped if condition is true
}

loop: for x in collection {
    for y in other {
        break loop      // breaks outer loop
    }
}
```

---

## Procedures

```odin
// Basic
add :: proc(a, b: int) -> int { return a + b }

// Multiple return values
swap :: proc(a, b: int) -> (int, int) { return b, a }

// Named return values
foo :: proc(x: int) -> (result: int, ok: bool) {
    result = x * 2
    ok = true
    return  // naked return
}

// Default parameter values (must be compile-time constants)
greet :: proc(name: string, loud := false) { }

// Named arguments at call site
create_window(title="Hello", width=800, height=600)

// Variadic parameters
sum :: proc(nums: ..int) -> (result: int) {
    for n in nums { result += n }
    return
}
sum(1, 2, 3)
my_slice := []int{1, 2, 3}
sum(..my_slice)  // spread slice as varargs

// Parameter mutation (must shadow)
foo :: proc(x: int) {
    x := x  // explicit copy to allow mutation
    x += 1
}

// Explicit overloading
to_string :: proc{int_to_string, bool_to_string, float_to_string}

// Procedure types
Callback :: proc(x: int) -> bool
my_cb: Callback = nil
my_cb = proc(x: int) -> bool { return x > 0 }

// Calling conventions
proc "c" (n: i32)            // C calling convention
proc "contextless" (x: int)  // Odin convention without context
proc "stdcall" (n: i32)      // Windows stdcall
```

---

## Arrays and Slices

### Fixed Arrays
```odin
a: [5]int                         // zero-initialized
a := [5]int{1, 2, 3, 4, 5}
a := [?]int{1, 2, 3, 4, 5}       // infer length from initializer
a := [?]int{0..=3 = 1}           // designated: [1,1,1,1]

len(a)                            // compile-time known length

// Array programming (element-wise ops)
v1 := [3]f32{1, 2, 3}
v2 := [3]f32{4, 5, 6}
v3 := v1 + v2                     // {5, 7, 9}
v4 := v1 * v2                     // {4, 10, 18}

// Swizzle (arrays len ≤ 4)
v := [3]f32{10, 20, 30}
v.xy                               // [2]f32{10, 20}
v.zyx                              // [3]f32{30, 20, 10}
swizzle(v, 2, 1, 0)               // same as v.zyx
```

### Slices
```odin
s: []int                          // nil slice
s = a[1:4]                        // slice of array [1,4)
s = a[:]                          // full slice
s = a[:3]                         // [0,3)
s = a[2:]                         // [2,len)

// Slice literal (allocates backing array)
s := []int{1, 2, 3}

len(s)
s[i]                              // bounds-checked by default

// Make/delete slices
s := make([]int, 100)
defer delete(s)
```

### Dynamic Arrays
```odin
d: [dynamic]int
defer delete(d)

append(&d, 1, 2, 3)
append(&d, ..some_slice)
pop(&d)
ordered_remove(&d, idx)
unordered_remove(&d, idx)        // O(1), swaps with last
clear(&d)                        // len=0, cap unchanged
reserve(&d, 100)
resize(&d, 50)
shrink(&d)

len(d)
cap(d)
d[:]                             // slice the dynamic array

// Make with initial size/capacity
d := make([dynamic]int, 0, 100)  // len=0, cap=100
defer delete(d)

// Sort
import "core:slice"
slice.sort(d[:])
```

### Fixed Capacity Dynamic Arrays

As of dev-2026-04, Odin has a first-class fixed-capacity dynamic array: `[dynamic; N]T`.
It is a value type backed by an inline `[N]T` array plus a length — no heap allocation,
no allocator needed. Think of it as a language-level replacement for the old
`base:runtime` / `core:container/small_array` `Small_Array(N, T)` pattern. The same
builtins (`append`, `pop`, `len`, `cap`, `clear`, slicing, etc.) work on it, and it
overflows/asserts rather than growing once it hits capacity `N`.

```odin
buf: [dynamic; 16]int            // inline storage for up to 16 ints, len starts at 0
append(&buf, 1, 2, 3)
fmt.println(len(buf), cap(buf))  // 3 16
buf[:]                           // slice view of the live elements
clear(&buf)
// No delete() needed — storage is inline, not heap-allocated.
```

Because it is a plain value, it copies by value and can live on the stack or be embedded
directly in a struct. `core:encoding/json` can unmarshal into it as of dev-2026-06.

---

## Maps

```odin
m := make(map[string]int)
defer delete(m)

m["key"] = 42
val := m["key"]                    // 0 if not found
val, ok := m["key"]                // comma-ok idiom
ok := "key" in m                   // membership check
delete_key(&m, "key")

len(m)
cap(m)
clear(&m)
reserve(&m, 100)

// Iteration
for key, value in m { }
for key, &value in m { value += 1 }  // mutate values

// Map literals (requires #+feature dynamic-literals in the file)
m := map[string]int{"a" = 1, "b" = 2}

// Modify existing value
ptr, ok := &m["key"]
if ok { ptr^ = new_value }
```

**Important:** Map literal syntax uses `=` not `:`: `"key" = value`

---

## Structs

```odin
Vec2 :: struct { x, y: f32 }

v := Vec2{1, 2}                   // positional
v := Vec2{y=2, x=1}              // named fields
v := Vec2{}                       // zero value

v.x = 3.0
p := &v
p.x = 4.0                         // auto-deref through pointer (no p^.x needed)

// Struct directives
struct #packed { ... }             // no padding
struct #align(16) { ... }         // alignment
struct #raw_union { ... }         // all fields at offset 0 (C union)

// Using (field promotion / subtype polymorphism)
Entity :: struct {
    using pos: Vec2,               // promotes x,y to Entity
    name: string,
}
e: Entity
e.x = 1.0                         // accesses pos.x

// Field tags
User :: struct {
    name: string `json:"username"`,
    age:  int    `json:"age,omitempty"`,
}

// Nested anonymous structs
Foo :: struct {
    inner: struct { a, b: int },
}
```

---

## Enums

```odin
Direction :: enum { North, East, South, West }

d := Direction.North
d = .North                         // implicit selector (type inferred)

// Explicit values
Color :: enum u8 { Red = 1, Green = 2, Blue = 4 }  // backing type u8

// Iteration
for dir in Direction { fmt.println(dir) }

// In switch
switch d {
case .North: ...
case .East: ...
case .South, .West: ...
}

// Enumerated arrays
Dir_Vectors :: [Direction][2]int{
    .North = {0, -1},
    .East  = {1, 0},
    .South = {0, 1},
    .West  = {-1, 0},
}
```

---

## Unions

Tagged/discriminated unions. Zero value is `nil`.

```odin
Value :: union { int, f32, string }

v: Value = 42
v = "hello"

// Type assertion
s := v.(string)                    // panics if wrong type
s, ok := v.(string)                // safe, ok=false if wrong
s = v.? or_else "default"         // with or_else (type inference)

// Type switch
switch val in v {
case int: fmt.println("int:", val)
case f32: fmt.println("f32:", val)
case string: fmt.println("string:", val)
case: fmt.println("nil")
}

// Partial type switch
#partial switch val in v {
case int: fmt.println("int:", val)
}

// Union tags
Value :: union #no_nil { int, string }     // no nil state, first variant is default
Value :: union #shared_nil { Err1, Err2 }  // nil variants collapse to nil
```

---

## Pointers and Multi-Pointers

```odin
// Pointers
p: ^int = nil
i := 42
p = &i          // address-of
val := p^       // dereference
p^ = 100        // write through pointer

// No pointer arithmetic! Use core:mem if needed:
// mem.ptr_offset(p, n)

// Multi-pointers (C-like array pointers)
mp: [^]int      // pointer to multiple ints
mp[0]           // index (no bounds check)
mp[1:5]         // slice with bounds (produces []int)
mp[:]           // produces [^]int (still multi-pointer)
mp[:n]          // produces []int

// Convert between
p: ^int = ...
mp: [^]int = p  // implicit ^T → [^]T
```

---

## Bit Sets

Mathematical set type. Implemented as bit vectors.

```odin
Direction :: enum { North, East, South, West }
Dir_Set :: bit_set[Direction]

s: Dir_Set = {.North, .West}
t: Dir_Set = {.North, .East}

// Set operations
s + t          // union: {.North, .West, .East}
s & t          // intersection: {.North}
s - t          // difference: {.West}
s ~ t          // symmetric difference: {.West, .East}
s <= t         // subset
s >= t         // superset
.North in s    // membership: true
.East not_in s // non-membership: true
card(s)        // cardinality: 2

// Range-based
Chars :: bit_set['A'..='Z']
Nums :: bit_set[0..<10; u16]  // with backing type
```

---

## Bit Fields

Bit-packed record type with explicit bit widths.

```odin
Flags :: bit_field u16 {
    read:    bool | 1,
    write:   bool | 1,
    execute: bool | 1,
    level:   u8   | 4,
    mode:    u8   | 3,
}

f := Flags{}
f.read = true
f.level = 7      // truncated to 4 bits
```

---

## Matrices

Built-in matrix type. Column-major storage by default. Max 64 elements (as of dev-2026-05; allows up to `matrix[8, 8]T`).

```odin
m: matrix[2, 3]f32 = {
    1, 2, 3,
    4, 5, 6,
}
elem := m[0, 1]               // row 0, col 1

// Matrix multiplication
a: matrix[2, 3]f32 = ...
b: matrix[3, 2]f32 = ...
c := a * b                     // matrix[2, 2]f32

// Matrix × array (vector)
v := [4]f32{1, 2, 3, 4}
result := m4x4 * v            // column vector
result2 := v * m4x4           // row vector

// Operations
transpose(m)
hadamard_product(a, b)         // component-wise multiply
matrix_flatten(m)              // to flat array

// Row-major storage
#row_major matrix[2, 3]f32
```

---

## SOA Types

Structure of Arrays — built-in layout transformation.

```odin
Particle :: struct { pos: [3]f32, vel: [3]f32, life: f32 }

// Fixed SOA array
particles: #soa[1000]Particle
particles[0].pos = {1, 2, 3}          // AoS-like access
particles.pos[0] = {1, 2, 3}          // SoA-like access (same address)

// SOA slice
s: #soa[]Particle = particles[:]

// SOA dynamic array
d: #soa[dynamic]Particle
append_soa(&d, Particle{{1,2,3}, {0,0,0}, 1.0})

// soa_zip — treat parallel slices as one SOA structure
xs := []f32{1, 2, 3}
ys := []f32{4, 5, 6}
for v in soa_zip(x=xs, y=ys) {
    fmt.println(v.x, v.y)
}

// soa_unzip — recover individual slices
a, b := soa_unzip(my_soa_slice)
```

---

## Operators

### Arithmetic
`+  -  *  /  %  %%` (% = truncated mod, %% = floored mod)

### Bitwise
`|  &  ~  &~  <<  >>` (~ = XOR, &~ = AND-NOT)

### Comparison
`==  !=  <  <=  >  >=`

### Logical
`&&  ||  !`

### Special
`in  not_in` — set/map membership
`..=  ..<` — inclusive/exclusive range
`or_else  or_return  or_continue  or_break`
`**x` — `expand_values` operator (dev-2026-06): shorthand for `expand_values(x)`, which
spreads a fixed array or struct's fields into a list of individual values (e.g. for passing
to a variadic procedure or a multi-value context). `**x == expand_values(x)`.

### Ternary
```odin
x if cond else y       // runtime
x when cond else y     // compile-time
cond ? x : y           // C-style (same as first form)
```

### Precedence (high → low)
```
7: *  /  %  %%  &  &~  <<  >>
6: +  -  |  ~  in  not_in
5: ==  !=  <  >  <=  >=
4: &&
3: ||
2: ..=  ..<
1: or_else  ?  if  when
```

---

## Type Conversions

```odin
// Standard conversion
f := f64(123)
i := int(f)

// Cast operator (same semantics, different syntax)
f := cast(f64)123

// Transmute (bitcast, must be same size)
u := transmute(u32)f32(1.0)

// Native array casting (dev-2026-05): `cast` now works between fixed-array
// and SIMD vector types of matching length, e.g. cast a #simd[4]u32 to a
// [4]f32 (and vice versa) without going through transmute.
v := cast([4]f32)some_simd_u32     // array <-> simd cast

// Auto cast (prototyping only — not recommended for production)
y: int = auto_cast x
```
