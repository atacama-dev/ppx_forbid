# ppx_forbid

[![CI](https://github.com/atacama-dev/ppx_forbid/actions/workflows/ci.yml/badge.svg)](https://github.com/atacama-dev/ppx_forbid/actions/workflows/ci.yml)

A configurable OCaml PPX that raises **compile-time errors** when forbidden functions or modules are used. Enforce coding standards automatically -- no more "please don't use X" in code review.

## Use cases

- **Eio migration**: ban blocking `Unix.open_process_in`, `Unix.sleep`, `Thread.create`
- **Safety**: ban `Obj.magic` and other unsafe operations
- **TUI apps**: ban `print_endline` / `Printf.printf` (they corrupt the terminal)
- **Theming**: ban hardcoded color functions, enforce themed helpers
- **API migration**: ban deprecated functions with actionable suggestions

## Quick start

```bash
opam install ppx_forbid
```

Add to your `dune` file:

```dune
(library
 (name mylib)
 (preprocess (pps ppx_forbid)))
```

Create a `.ppx_forbid` config in your project:

```
module Obj "Obj is unsafe and breaks type safety"
function Unix.sleep "Use Eio.Time.sleep"
function Thread.create "Use Eio.Fiber.fork"
```

That's it. Any use of `Obj`, `Unix.sleep`, or `Thread.create` will now fail to compile:

```
File "src/myfile.ml", line 42, characters 10-30:
42 |   let _ = Unix.sleep 5 in
              ^^^^^^^^^^
Error: Forbidden call: Unix.sleep is not allowed.
Suggestion: Use Eio.Time.sleep
Use [@allow_forbidden "reason"] to suppress.
```

Unqualified Stdlib functions are also caught -- `prerr_endline` matches a `function Stdlib.prerr_endline` rule.

## Config file format

```
# Comments start with #

# Forbid an entire module
module <ModuleName> "<reason>"

# Forbid a specific function
function <Module.function_name> "<suggestion>"

# Enable pattern detection
pattern unresolved_lwt

# Include another config file (paths relative to this file)
include ../base.ppx_forbid
```

### Per-directory configs

The PPX searches for `.ppx_forbid` starting from the **source file's directory** and walking up to the project root. This lets you have stricter rules for specific subdirectories:

```
project/
  .ppx_forbid              # project-wide rules
  src/
    ui/
      .ppx_forbid          # UI-specific rules (can `include ../../.ppx_forbid`)
```

You can also pass an explicit config path:

```dune
(preprocess (pps (ppx_forbid --config .ppx_forbid.strict)))
```

## Suppression

When you genuinely need a forbidden function, annotate with `[@allow_forbidden "reason"]`:

```ocaml
(* On an expression *)
let raw = (Obj.magic ptr : bytes) [@allow_forbidden "FFI boundary"]

(* On a binding *)
let[@allow_forbidden "logger writes to stderr by design"] log msg =
  prerr_endline msg
```

The reason string is required and documents *why* the exception is acceptable.

## Pattern Detection

Beyond forbidding specific functions or modules, ppx_forbid can detect dangerous code patterns.

### Unresolved Lwt.t Bindings

Catches cases where Lwt promises are bound but never resolved, which can lead to promises being garbage collected before execution.

Enable in `.ppx_forbid`:
```
pattern unresolved_lwt
```

**Examples:**

❌ **Forbidden** (promise may be garbage collected):
```ocaml
let _ : unit Lwt.t = async_operation ()
let _ignored : int Lwt.t = fetch_data ()
```

✅ **Allowed** (promise is resolved or explicitly ignored):
```ocaml
let* () = async_operation ()              (* Resolved with let* *)
let+ x = fetch_data ()                     (* Resolved with let+ *)
Lwt.ignore_result (async_operation ())     (* Explicitly ignored *)
let x = async_operation ()                 (* Named binding - compiler warns if unused *)
```

**Note:** This check only applies when type annotations are explicit (`: unit Lwt.t`). Adding type annotations to side-effectful Lwt code is recommended for safety.

## Default rules

When no `.ppx_forbid` file is found, a single default rule applies:

| Item | Reason |
|------|--------|
| `Obj` (module) | Obj is unsafe and breaks type safety |

## Real-world example

Project-wide config (`.ppx_forbid`):

```
module Obj "Obj is unsafe and breaks type safety"

function Unix.open_process_in "Use Eio.Process.run or Common.run_out"
function Unix.open_process_out "Use Eio.Process.run"
function Unix.system "Use Eio.Process.run or Common.run"
function Unix.sleep "Use Eio.Time.sleep"
function Thread.create "Use Eio.Fiber.fork or Eio.Fiber.fork_daemon"
```

TUI-specific config (`src/ui/.ppx_forbid`):

```
include ../../.ppx_forbid

function Stdlib.print_endline "Use logging or TUI display functions"
function Stdlib.prerr_endline "Use logging or Toast notifications"
function Printf.printf "Use logging or TUI display functions"
```

## Requirements

- OCaml >= 4.14
- ppxlib >= 0.28.0

## License

[GPL-3.0-or-later](LICENSE)
