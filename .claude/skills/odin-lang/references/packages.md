# Odin Packages Reference

Odin has three library collections: `base`, `core`, and `vendor`.

Import syntax: `import "collection:path/to/package"`

---

## Base Library (`base:`)

Fundamental packages required by all Odin programs.

| Package | Import | Description |
|---------|--------|-------------|
| builtin | `base:builtin` | Predeclared identifiers: `len`, `cap`, `append`, `delete`, `make`, `new`, `free`, `size_of`, `align_of`, `type_of`, `typeid_of`, `copy`, `clear`, `pop`, `assert`, `panic`, `raw_data`, `swizzle`, `min`, `max`, `clamp`, `abs`, `resize`, `reserve`, `shrink`, `soa_zip`, `soa_unzip`, `ordered_remove`, `unordered_remove`, `inject_at`, `assign_at`, `card` (cardinality), `transmute`, `auto_cast` |
| intrinsics | `base:intrinsics` | Compiler intrinsics: type checking (`type_is_*`), SIMD, atomics, math intrinsics, `transpose`, `outer_product`, `hadamard_product`, `matrix_flatten`, `conj` |
| runtime | `base:runtime` | Runtime support: `Context`, `Type_Info`, `Source_Code_Location`, `default_context`, allocator interfaces, `Tracking_Allocator` (in `core:mem`) |

---

## Core Library (`core:`)

The standard library. All packages listed by category.

### I/O and File System
| Package | Import | Description |
|---------|--------|-------------|
| fmt | `core:fmt` | Formatted I/O (printf-style). `println`, `printf`, `sprintf`, `tprintf` (temp alloc), `sbprintf` (string builder) |
| os | `core:os` | Cross-platform file I/O, environment, args, paths, processes. New API (replaced old `core:os` in dev-2026-03; was previously `core:os/os2`): file handles are `^os.File`, errors are `os.Error`, allocating procs require an explicit allocator. Procs: `open`, `close`, `read`, `write`, `read_entire_file(path, allocator)`, `write_entire_file`. Old API available at `core:os/old` until Q3 2026 |
| io | `core:io` | Generic stream interfaces (`Reader`, `Writer`, `Closer`, `Seeker`) |
| bufio | `core:bufio` | Buffered I/O wrapping `io.Stream` |
| log | `core:log` | Logging: `info`, `warn`, `error`, `fatal`, `debug`. Integrates with `context.logger` |
| nbio | `core:nbio` | Non-blocking I/O / event loop abstraction |

### Strings and Text
| Package | Import | Description |
|---------|--------|-------------|
| strings | `core:strings` | String builder, manipulation, clone, split, join, trim, contains, replace, to_upper/lower, `clone_to_cstring`, `string_from_ptr` |
| strconv | `core:strconv` | String ↔ number conversions: `atoi`, `itoa`, `parse_int`, `parse_f64` |
| unicode | `core:unicode` | Unicode code point properties |
| unicode/utf8 | `core:unicode/utf8` | UTF-8 encoding/decoding, `string_to_runes`, `runes_to_string`, `rune_count` |
| unicode/utf16 | `core:unicode/utf16` | UTF-16 encoding/decoding |
| text/regex | `core:text/regex` | Regular expression matching and capture |
| text/match | `core:text/match` | Lua-like string pattern matching |
| text/scanner | `core:text/scanner` | UTF-8 text tokenizer |
| text/table | `core:text/table` | Plain-text/markdown/HTML table rendering |
| text/edit | `core:text/edit` | Text edit primitives (for text boxes) |
| text/i18n | `core:text/i18n` | Internationalization support |

### Data Structures
| Package | Import | Description |
|---------|--------|-------------|
| slice | `core:slice` | Slice utilities: `sort`, `reverse_sort`, `contains`, `linear_search`, `binary_search`, `filter`, `map_entries`, `reverse` |
| sort | `core:sort` | Sorting interface and algorithms |
| container/queue | `core:container/queue` | Double-ended queue / ring buffer |
| container/priority_queue | `core:container/priority_queue` | Priority queue |
| container/small_array | `core:container/small_array` | Stack-allocated dynamic array (no heap). Note: the language now has a built-in equivalent, the fixed-capacity dynamic array `[dynamic; N]T` (dev-2026-04) — prefer it for new code |
| container/bit_array | `core:container/bit_array` | Dynamically-sized bit array |
| container/avl | `core:container/avl` | AVL tree |
| container/rbtree | `core:container/rbtree` | Red-black tree |
| container/lru | `core:container/lru` | LRU cache |
| container/pool | `core:container/pool` | Object pool |
| container/handle_map | `core:container/handle_map` | Generational-index handle containers; `Static_Handle_Map(N, T, H)` (fixed) and `Dynamic_Handle_Map(T, H)` (growable). Stable handles survive removal/reuse |
| container/xar | `core:container/xar` | Exponential arrays — grow in exponentially-sized chunks; elements never move, so pointers to elements stay valid (unlike `[dynamic]T`) |
| container/intrusive/list | `core:container/intrusive/list` | Intrusive doubly-linked list |
| container/topological_sort | `core:container/topological_sort` | Topological sort O(V+E) |

### Memory
| Package | Import | Description |
|---------|--------|-------------|
| mem | `core:mem` | Allocators (`Tracking_Allocator`, `Arena_Allocator`), pointer helpers, slice helpers, `ptr_offset`, `ptr_sub` |
| mem/virtual | `core:mem/virtual` | Virtual memory: reserve/commit/decommit |
| mem/tlsf | `core:mem/tlsf` | Two Level Segregated Fit allocator |

### Math
| Package | Import | Description |
|---------|--------|-------------|
| math | `core:math` | Trig, sqrt, pow, log, floor, ceil, round, min, max, clamp, abs, inf, nan, PI, E, TAU |
| math/linalg | `core:math/linalg` | Linear algebra: matrix ops, vector ops, quaternions, transformations, `determinant`, `inverse`, `identity` |
| math/linalg/glsl | `core:math/linalg/glsl` | GLSL-compatible math (vec2, vec3, vec4, mat4, etc.) |
| math/linalg/hlsl | `core:math/linalg/hlsl` | HLSL-compatible math |
| math/rand | `core:math/rand` | Random numbers: `float32`, `float64`, `int_max`, `shuffle`, `choice` |
| math/big | `core:math/big` | Arbitrary precision integers and rationals |
| math/noise | `core:math/noise` | OpenSimplex2 noise |
| math/bits | `core:math/bits` | Bit manipulation utilities |
| math/cmplx | `core:math/cmplx` | Complex number math |
| math/ease | `core:math/ease` | Easing functions for animation |

### Encoding
| Package | Import | Description |
|---------|--------|-------------|
| encoding/json | `core:encoding/json` | JSON encode/decode (strict, JSON5, BitSquid variants) |
| encoding/xml | `core:encoding/xml` | XML parser |
| encoding/csv | `core:encoding/csv` | CSV reader/writer (RFC 4180) |
| encoding/ini | `core:encoding/ini` | INI file reader/writer |
| encoding/base64 | `core:encoding/base64` | Base64 encode/decode |
| encoding/base32 | `core:encoding/base32` | Base32 encode/decode |
| encoding/hex | `core:encoding/hex` | Hex encode/decode |
| encoding/cbor | `core:encoding/cbor` | CBOR binary encode/decode |
| encoding/uuid | `core:encoding/uuid` | UUID generation (RFC 4122/9562) |
| encoding/varint | `core:encoding/varint` | LEB128 variable-length integers |
| encoding/pem | `core:encoding/pem` | PEM encode/decode (initial support, dev-2026-06) |

### Networking
| Package | Import | Description |
|---------|--------|-------------|
| net | `core:net` | Berkeley sockets, DNS resolution, TCP/UDP |

### Concurrency
| Package | Import | Description |
|---------|--------|-------------|
| sync | `core:sync` | Mutexes, condition variables, semaphores, barriers, once |
| sync/chan | `core:sync/chan` | Typed channels for thread communication |
| thread | `core:thread` | Thread creation, thread pools |

### Cryptography
| Package | Import | Description |
|---------|--------|-------------|
| crypto | `core:crypto` | Random bytes, constant-time comparison |
| crypto/aes | `core:crypto/aes` | AES block cipher |
| crypto/sha2 | `core:crypto/sha2` | SHA-256, SHA-512 |
| crypto/sha3 | `core:crypto/sha3` | SHA-3 family |
| crypto/blake2b | `core:crypto/blake2b` | BLAKE2b hash |
| crypto/chacha20poly1305 | `core:crypto/chacha20poly1305` | AEAD encryption |
| crypto/ed25519 | `core:crypto/ed25519` | EdDSA signatures |
| crypto/x25519 | `core:crypto/x25519` | ECDH key exchange |
| crypto/hmac | `core:crypto/hmac` | HMAC message auth |
| crypto/hkdf | `core:crypto/hkdf` | Key derivation |
| crypto/pbkdf2 | `core:crypto/pbkdf2` | Password-based key derivation |
| crypto/ecdh | `core:crypto/ecdh` | Unified ECDH over X25519/X448 |
| crypto/ml_kem | `core:crypto/ml_kem` | ML-KEM (FIPS 203) post-quantum key encapsulation (dev-2026-06) |
| crypto/ml_dsa | `core:crypto/ml_dsa` | ML-DSA (FIPS 204) post-quantum digital signatures (dev-2026-06) |

### Image Processing
| Package | Import | Description |
|---------|--------|-------------|
| image | `core:image` | General image types |
| image/png | `core:image/png` | PNG reader |
| image/bmp | `core:image/bmp` | BMP reader/writer |
| image/jpeg | `core:image/jpeg` | Baseline JPEG reader |
| image/tga | `core:image/tga` | TGA reader/writer |
| image/qoi | `core:image/qoi` | QOI reader/writer |

### Compression
| Package | Import | Description |
|---------|--------|-------------|
| compress/zlib | `core:compress/zlib` | Deflate/ZLIB decompression |
| compress/gzip | `core:compress/gzip` | GZIP decompression |

### System
| Package | Import | Description |
|---------|--------|-------------|
| time | `core:time` | Time types, `now`, `sleep`, durations, formatting |
| dynlib | `core:dynlib` | Dynamic library loading (dlopen/LoadLibrary) |
| sys/info | `core:sys/info` | System info (CPU, RAM, OS). API changed in 2026 from `@(init)`-populated globals to on-demand accessor procs (cached where practical, e.g. CPU name/features) |
| sys/posix | `core:sys/posix` | POSIX API bindings |
| sys/linux | `core:sys/linux` | Linux syscall bindings |
| sys/windows | `core:sys/windows` | Windows API bindings |
| sys/darwin | `core:sys/darwin` | macOS API bindings |
| terminal | `core:terminal` | Terminal/CLI interaction |

### Other
| Package | Import | Description |
|---------|--------|-------------|
| testing | `core:testing` | Test runner and assertion procedures |
| reflect | `core:reflect` | Runtime type introspection (RTTI) |
| hash | `core:hash` | Non-crypto hashes: CRC32, CRC64, Adler32, FNV, DJB, Murmur |
| hash/xxhash | `core:hash/xxhash` | xxHash |
| flags | `core:flags` | Command-line argument parsing |
| bytes | `core:bytes` | Byte slice manipulation |
| c | `core:c` | C type definitions for FFI |
| c/libc | `core:c/libc` | C standard library declarations |
| path/filepath | `core:path/filepath` | OS-aware file path manipulation |
| path/slashpath | `core:path/slashpath` | Forward-slash path manipulation (URLs) |
| prof/spall | `core:prof/spall` | Spall format profiling |
| simd | `core:simd` | Cross-platform SIMD types and ops |
| relative | `core:relative` | Relative pointers and slices |
| odin/parser | `core:odin/parser` | Odin source parser (for tooling) |
| odin/tokenizer | `core:odin/tokenizer` | Odin lexer (for tooling) |
| odin/ast | `core:odin/ast` | Odin AST types (for tooling) |
| debug/trace | `core:debug/trace` | Stack traces (requires `-debug`) |

---

## Vendor Library (`vendor:`)

Third-party bindings and ports bundled with Odin.

### Graphics & Windowing
| Package | Import | Description |
|---------|--------|-------------|
| glfw | `vendor:glfw` | GLFW windowing/input |
| OpenGL | `vendor:OpenGL` | OpenGL 4.6 core profile loader |
| vulkan | `vendor:vulkan` | Vulkan API wrapper |
| wgpu | `vendor:wgpu` | WebGPU cross-platform API |
| raylib | `vendor:raylib` | raylib v5.5 game library |
| sdl2 | `vendor:sdl2` | SDL2 bindings |
| sdl3 | `vendor:sdl3` | SDL3 bindings |
| directx/d3d11 | `vendor:directx/d3d11` | Direct3D 11 |
| directx/d3d12 | `vendor:directx/d3d12` | Direct3D 12 |
| darwin/Metal | `vendor:darwin/Metal` | Apple Metal |

### Audio
| Package | Import | Description |
|---------|--------|-------------|
| miniaudio | `vendor:miniaudio` | Cross-platform audio |
| portmidi | `vendor:portmidi` | MIDI I/O |
| sdl2/mixer | `vendor:sdl2/mixer` | SDL2 audio mixer |

### UI
| Package | Import | Description |
|---------|--------|-------------|
| microui | `vendor:microui` | Immediate mode UI (native port) |

### 2D Graphics
| Package | Import | Description |
|---------|--------|-------------|
| nanovg | `vendor:nanovg` | Vector graphics (native port) |
| fontstash | `vendor:fontstash` | Font atlas/rendering (native port) |

### Physics
| Package | Import | Description |
|---------|--------|-------------|
| box2d | `vendor:box2d` | Box2D physics engine |

### Image
| Package | Import | Description |
|---------|--------|-------------|
| stb/image | `vendor:stb/image` | stb_image loading |
| stb/truetype | `vendor:stb/truetype` | stb_truetype font loading |
| sdl2/image | `vendor:sdl2/image` | SDL2 image loading |
| OpenEXRCore | `vendor:OpenEXRCore` | OpenEXR image format |

### Networking
| Package | Import | Description |
|---------|--------|-------------|
| ENet | `vendor:ENet` | Reliable UDP networking |
| curl | `vendor:curl` | libcurl HTTP client |
| sdl2/net | `vendor:sdl2/net` | SDL2 networking |

### 3D Assets
| Package | Import | Description |
|---------|--------|-------------|
| cgltf | `vendor:cgltf` | glTF 2.0 loader |

### Compression
| Package | Import | Description |
|---------|--------|-------------|
| compress/lz4 | `vendor:compress/lz4` | LZ4 compression |
| zlib | `vendor:zlib` | zlib compression library |

### Scripting
| Package | Import | Description |
|---------|--------|-------------|
| lua/5.4 | `vendor:lua/5.4` | Lua 5.4 bindings |

### Text
| Package | Import | Description |
|---------|--------|-------------|
| commonmark | `vendor:commonmark` | CommonMark/Markdown parser |
| kb_text_shape | `vendor:kb_text_shape` | Unicode text shaping |

### Game Networking
| Package | Import | Description |
|---------|--------|-------------|
| ggpo | `vendor:ggpo` | GGPO rollback networking |

---

## Package Documentation

Full documentation: https://pkg.odin-lang.org/

- Base: https://pkg.odin-lang.org/base/
- Core: https://pkg.odin-lang.org/core/
- Vendor: https://pkg.odin-lang.org/vendor/
