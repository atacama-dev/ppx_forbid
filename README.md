# ppx_forbid

A configurable PPX rewriter that forbids specific function calls or modules at compile time.

## Overview

`ppx_forbid` helps enforce coding standards by raising compilation errors when forbidden functions or modules are used. Common use cases:

- **Eio projects**: Forbid blocking `Unix.open_process_in`, `Unix.sleep`, `Thread.create` to ensure non-blocking code
- **Safety**: Forbid `Obj.magic` and other unsafe operations  
- **API migration**: Forbid deprecated functions with suggestions for replacements

## Installation

```bash
opam install ppx_forbid
```

## Usage

Add to your `dune` file:

```dune
(library
 (name mylib)
 (preprocess (pps ppx_forbid)))
```

## Configuration

Create a `.ppx_forbid` file in your project root:

```
# Forbid entire modules
module Obj "Obj is unsafe and breaks type safety"

# Forbid specific functions with suggestions
function Unix.open_process_in "Use Eio.Process.run instead"
function Unix.sleep "Use Eio.Time.sleep"
function Thread.create "Use Eio.Fiber.fork"
```

If no config file is found, only `Obj` is forbidden by default.

## Suppression

Use `[@allow_forbidden "reason"]` to suppress the check when necessary:

```ocaml
(* Allowed with justification *)
let result = 
  (Obj.magic value : target_type) 
  [@allow_forbidden "FFI boundary requires type coercion"]

(* Allowed on entire binding *)
let legacy_wrapper =
  (fun cmd -> Unix.open_process_in cmd)
  [@allow_forbidden "Legacy code - TODO: migrate to Eio"]
```

## Example Error

```
File "src/myfile.ml", line 42, characters 10-30:
42 |   let ic = Unix.open_process_in cmd in
              ^^^^^^^^^^^^^^^^^^^^
Error: Forbidden call: Unix.open_process_in is not allowed.
Suggestion: Use Eio.Process.run instead
Use [@allow_forbidden "reason"] to suppress.
```

## Config File Format

```
# Comments start with #

# Forbid a module (all functions)
module <ModuleName> "<reason>"

# Forbid a specific function
function <Module.function> "<suggestion>"
```

## Default Rules

When no `.ppx_forbid` file is found:

| Item | Reason |
|------|--------|
| `Obj` (module) | Obj is unsafe and breaks type safety |

## License

MIT
