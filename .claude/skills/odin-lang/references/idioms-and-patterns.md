# Odin Idioms and Patterns Reference

## Table of Contents
1. [Error Handling](#error-handling)
2. [Implicit Context System](#implicit-context-system)
3. [Memory and Allocators](#memory-and-allocators)
4. [Foreign System (C Interop)](#foreign-system)
5. [Parametric Polymorphism (Generics)](#parametric-polymorphism)
6. [Attributes and Directives](#attributes-and-directives)
7. [Testing](#testing)
8. [Conditional Compilation](#conditional-compilation)
9. [Common Patterns](#common-patterns)

---

## Error Handling

Odin uses multi-return values and explicit error checking. No exceptions.

### or_return
Pops the last value from a multi-return expression. If it's non-nil (error) or false (ok), sets the corresponding named return value and returns immediately.

```odin
// Without or_return
load :: proc() -> (data: []byte, err: Error) {
    file, file_err := open("config.txt")
    if file_err != nil {
        err = file_err
        return
    }
    // ...
}

// With or_return — much cleaner
load :: proc() -> (data: []byte, err: Error) {
    file := open("config.txt") or_return
    content := read_all(file) or_return
    return content, nil
}
```

**Rules for or_return:**
- If the procedure has multiple return values, ALL must be named
- Works with error-type returns (nil check) and ok-type returns (bool check)
- Pops only the LAST value in the multi-return

### or_else
Provides a default value when the "ok" part of an optional-ok expression is false or the error part is non-nil.

```odin
// Map lookup with default
val := my_map["key"] or_else 0

// Union type assertion with default
x: union{int, string} = "hello"
n := x.(int) or_else -1

// Maybe type
m: Maybe(int)
val := m.? or_else 42
```

### or_continue / or_break
Used in loops. Same mechanics as or_return but performs continue/break instead of return.

```odin
for &job in jobs {
    result := process(&job) or_continue  // skip failed jobs
    fmt.println("Result:", result)
}

for &item in items {
    val := validate(item) or_break  // stop on first failure
    use(val)
}

// With labels
outer: for &batch in batches {
    for &item in batch.items {
        process(item) or_continue outer  // skip entire batch
    }
}
```

### Error Enum Pattern
```odin
Error :: enum {
    None,
    File_Not_Found,
    Permission_Denied,
    Parse_Error,
}

// Combine with union for rich errors
Rich_Error :: union {
    IO_Error,
    Parse_Error,
    Validation_Error,
}
```

### Maybe Type
```odin
// From base:runtime
Maybe :: union($T: typeid) { T }

find :: proc(items: []Item, id: int) -> Maybe(Item) {
    for item in items {
        if item.id == id { return item }
    }
    return nil
}

item := find(items, 42).? or_else Item{}
```

---

## Implicit Context System

Every Odin procedure (with "odin" calling convention) receives an implicit `context` parameter.

```odin
// The context contains:
Context :: struct {
    allocator:         Allocator,
    temp_allocator:    Allocator,
    logger:            Logger,
    assertion_failure_proc: proc(...),
    // ... and more
}
```

### Using context
```odin
main :: proc() {
    // context is implicitly available
    context.allocator = my_custom_allocator

    // All called procedures inherit this context
    do_stuff()  // uses my_custom_allocator
}

// Override for a scope
{
    context.allocator = temp_allocator
    // everything in this scope uses temp_allocator
    data := make([]byte, 1024)  // allocated with temp_allocator
}
```

### Explicit Context Definition (for C callbacks)
```odin
// When called from C, there's no context. You must set one up:
@(export)
my_c_callback :: proc "c" (data: rawptr) {
    context = runtime.default_context()
    // Now you can use Odin features that need context
    fmt.println("Called from C")
}
```

---

## Memory and Allocators

Odin has no garbage collector. Memory management is explicit through allocators.

### Basic Allocation
```odin
// Heap allocation via context.allocator
ptr := new(int)
defer free(ptr)

slice := make([]int, 100)
defer delete(slice)

dyn := make([dynamic]int, 0, 64)
defer delete(dyn)

m := make(map[string]int)
defer delete(m)

// Aligned allocation: as of dev-2026-06, `new_aligned` and `make_aligned`
// are builtins (no import needed) for over-aligned allocations.
p := new_aligned(Vec4, 32)         // pointer aligned to 32 bytes
buf := make_aligned([]u8, 1024, 64) // slice with 64-byte alignment
```

### Tracking Allocator (for finding leaks)
```odin
import "core:mem"

main :: proc() {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)
    defer {
        if len(track.allocation_map) > 0 {
            for _, entry in track.allocation_map {
                fmt.eprintf("Leak: %v bytes at %v\n", entry.size, entry.location)
            }
        }
        if len(track.bad_free_array) > 0 {
            for entry in track.bad_free_array {
                fmt.eprintf("Bad free at %v\n", entry.location)
            }
        }
        mem.tracking_allocator_destroy(&track)
    }

    // All code here is tracked for leaks
}
```

### Temp Allocator (arena-style, bulk free)
```odin
// Temp allocator is available via context.temp_allocator
// Useful for per-frame or per-request allocations
{
    temp_str := fmt.tprintf("Hello %s", name)  // uses temp allocator
    // ...
}
// Call free_all on temp allocator periodically:
free_all(context.temp_allocator)
```

### Custom Allocator with Specific Containers
```odin
// Pass allocator explicitly
d := make([dynamic]int, 0, 64, my_allocator)
defer delete(d)

// Maps
m := make(map[string]int, my_allocator)
defer delete(m)
```

---

## Foreign System

For interfacing with C libraries.

```odin
// Import a C library
foreign import lib "system:SDL2"

// Declare foreign procedures
foreign lib {
    @(link_name="SDL_Init")
    sdl_init :: proc "c" (flags: u32) -> i32 ---

    @(link_name="SDL_Quit")
    sdl_quit :: proc "c" () ---
}

// Foreign block default calling convention is "cdecl" / "c"
```

### C Type Interop
```odin
import "core:c"

// Common C types available:
// c.int, c.uint, c.char, c.size_t, c.ptrdiff_t, etc.

// Use cstring for C strings
foreign lib {
    puts :: proc "c" (s: cstring) -> c.int ---
}

// Convert Odin string to cstring
odin_str := "hello"
c_str := strings.clone_to_cstring(odin_str)
defer delete(c_str)
puts(c_str)
```

---

## Parametric Polymorphism

Odin uses `$` to denote compile-time polymorphic parameters.

```odin
// Generic procedure
print_array :: proc(arr: []$T) {
    for val in arr {
        fmt.println(val)
    }
}

// Works with any element type
print_array([]int{1, 2, 3})
print_array([]string{"a", "b"})

// Generic struct
Stack :: struct($T: typeid) {
    data: [dynamic]T,
}

push :: proc(s: ^Stack($T), val: T) {
    append(&s.data, val)
}

// Where clauses (type constraints)
add :: proc(a, b: $T) -> T where intrinsics.type_is_numeric(T) {
    return a + b
}

// Specialization with where clauses
serialize :: proc(val: $T) -> []byte where intrinsics.type_is_struct(T) { ... }
serialize :: proc(val: $T) -> []byte where intrinsics.type_is_integer(T) { ... }
```

---

## Attributes and Directives

### Common Attributes
```odin
@(private)              // package-private
@(private="file")       // file-private
@(export)               // export symbol for foreign use
@(link_name="c_name")   // specify C symbol name
@(deprecated="Use X")   // mark as deprecated
@(require)              // force import to be included
@(test)                 // mark as test procedure
@(init)                 // run at program startup
@(cold)                 // hint: rarely called
@(disabled)             // compile but don't include
@(deferred_out=proc)    // auto-call proc with return values at scope exit
@(fast_math)            // (dev-2026-06) enable fast (relaxed/reassociating) float math for the proc
```

### Common Directives
```odin
#assert(condition)           // compile-time assert
#panic("message")            // compile-time panic
#config(IDENTIFIER, default) // compile-time config flag

#partial switch ...           // allow non-exhaustive enum/union switch
#no_bounds_check { ... }      // disable bounds checking
#bounds_check { ... }         // enable bounds checking
#reverse for ...              // reverse iteration
#unroll for ...               // compile-time loop unroll
#soa[N]Type                   // SOA layout
#row_major matrix[...]        // row-major matrix storage
#sparse                       // sparse enumerated array

size_of(T)                    // size in bytes
align_of(T)                   // alignment
offset_of(T, field)           // field offset
type_of(expr)                 // get type of expression
typeid_of(T)                  // get typeid
type_info_of(id)              // get Type_Info from typeid
```

---

## Testing

### Test Basics
Tests use `@(test)` attribute and accept `^testing.T`.

```odin
package my_tests

import "core:testing"
import "core:log"

@(test)
test_basic :: proc(t: ^testing.T) {
    // Simple boolean check
    testing.expect(t, 2 + 2 == 4, "basic math failed")

    // Value comparison (auto-generates error message)
    testing.expect_value(t, compute(), 42)

    // Formatted error message
    testing.expectf(t, val > 0, "expected positive, got %d", val)

    // Explicit fail
    testing.fail(t)

    // Fail and stop immediately (divergent)
    testing.fail_now(t)

    // Set timeout
    testing.set_fail_timeout(t, 5 * time.Second)
}

// Logging in tests
@(test)
test_with_logging :: proc(t: ^testing.T) {
    log.info("Starting test")
    log.warnf("Value is %d", val)
    // error/fatal log = test failure
}

// Cleanup for crash safety
@(test)
test_with_cleanup :: proc(t: ^testing.T) {
    fd, _ := os.open("test_file")
    testing.cleanup(t, proc(raw: rawptr) {
        handle := cast(^^os.File)raw
        os.close(handle^)
    }, &fd)
}
```

### Running Tests
```bash
odin test .
odin test . -all-packages              # include imported packages
odin test . -define:ODIN_TEST_THREADS=4
odin test . -define:ODIN_TEST_TRACK_MEMORY=false
odin test . -define:ODIN_TEST_LOG_LEVEL=warning
odin test . -define:ODIN_TEST_NAMES=pkg.test_name
odin test . -define:ODIN_TEST_SHORT_LOGS=true
```

### Test Runner Features
- Multi-threaded by default (one test per thread)
- Memory tracking: reports leaks and bad frees
- Thread-safe logging per test
- Graceful handling of segfaults, asserts, panics
- Random seed shared across all tests (reproducible)
- ANSI colored progress output
- CTRL-C to cancel early

### Multi-Package Test Organization
```
tests/
├── tests.odin          # imports sub-packages
├── foo/
│   └── foo_test.odin
├── bar/
│   └── bar_test.odin
```

```odin
// tests/tests.odin
package tests
@require import "foo"
@require import "bar"
```

Run: `odin test tests/ -all-packages`

---

## Conditional Compilation

### File Suffixes
Files can have platform suffixes that control inclusion:
- `foo_windows.odin` — Windows only
- `foo_linux.odin` — Linux only
- `foo_darwin.odin` — macOS only
- `foo_amd64.odin` — AMD64 only
- `foo_windows_amd64.odin` — Windows AMD64 only

### when Statements
```odin
when ODIN_OS == .Windows {
    import win "core:sys/windows"
} else when ODIN_OS == .Linux {
    import linux "core:sys/linux"
}
```

### Built-in Constants for `when`
| Constant | Description |
|----------|-------------|
| `ODIN_OS` | `.Windows`, `.Linux`, `.Darwin`, `.FreeBSD`, etc. |
| `ODIN_ARCH` | `.amd64`, `.arm64`, `.i386`, `.wasm32`, etc. |
| `ODIN_DEBUG` | `true` if `-debug` flag used |
| `ODIN_ENDIAN` | `.Little` or `.Big` |
| `ODIN_OS_STRING` | String version of OS |
| `ODIN_ARCH_STRING` | String version of arch |
| `ODIN_BUILD_MODE` | `.Executable`, `.Dynamic`, `.Static`, etc. |

### #config
```odin
// Define at command line: -define:MY_FLAG=true
MY_FLAG :: #config(MY_FLAG, false)  // default = false

when MY_FLAG {
    // conditional code
}
```

---

## Common Patterns

### Builder / Init Pattern
```odin
Server :: struct {
    host: string,
    port: int,
    // ...
}

server_init :: proc(host := "localhost", port := 8080) -> Server {
    return Server{host=host, port=port}
}

server_destroy :: proc(s: ^Server) {
    // cleanup
}
```

### Interface-like Pattern (procedure table)
```odin
Writer :: struct {
    data: rawptr,
    write: proc(data: rawptr, buf: []byte) -> (int, Error),
    close: proc(data: rawptr) -> Error,
}

write :: proc(w: Writer, buf: []byte) -> (int, Error) {
    return w.write(w.data, buf)
}
```

### Subtype Polymorphism
```odin
Entity :: struct {
    id: int,
    using transform: Transform,
}

Player :: struct {
    using base: Entity,
    health: int,
}

// Player values can be passed where Entity is expected
update_entity :: proc(e: Entity) { ... }

p := Player{base={id=1, transform={...}}, health=100}
update_entity(p)  // works! Player promotes to Entity
```

### Resource Handle Pattern
```odin
Handle :: distinct u32
INVALID_HANDLE :: Handle(0)

Pool :: struct {
    items: [dynamic]Item,
    free_list: [dynamic]int,
}

pool_acquire :: proc(p: ^Pool) -> Handle { ... }
pool_release :: proc(p: ^Pool, h: Handle) { ... }
pool_get :: proc(p: ^Pool, h: Handle) -> ^Item { ... }
```

### Defer Pattern for Paired Operations
```odin
// Any open/close, lock/unlock, push/pop pair
mutex_lock(&m)
defer mutex_unlock(&m)

timer_start(&t)
defer timer_stop(&t)

begin_frame()
defer end_frame()
```

### Using for Field Promotion
```odin
// Bring all fields of a sub-struct into scope
process :: proc(using entity: ^Entity) {
    // Can access entity.x as just x
    x += velocity.x
    y += velocity.y
}
```

> **Note (2026):** `using` on **struct fields** (as in the Subtype Polymorphism example
> above) still works by default and is unchanged. However, `using` as a **statement**
> (e.g. `using foo` inside a procedure body) and `using` as a **procedure-parameter
> modifier** (the `proc(using entity: ^Entity)` form above) are now **opt-in per file**.
> To use either form, add `#+feature using-stmt` at the top of the file. Prefer accessing
> fields explicitly (`entity.x`) in new code to avoid needing the feature flag.
