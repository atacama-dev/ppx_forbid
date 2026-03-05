(******************************************************************************)
(*                                                                            *)
(* SPDX-License-Identifier: GPL-3.0-or-later                                               *)
(* Copyright (c) 2026 Mathias Bourgoin <mathias.bourgoin@atacama.tech>        *)
(*                                                                            *)
(******************************************************************************)

(** Test that properly resolved Lwt.t bindings are allowed *)

(* Top-level examples *)

(* Using let* to resolve - this is OK *)
let example1 () =
  let open Lwt.Syntax in
  let* () = Lwt.return () in
  let* x = Lwt.return 42 in
  Lwt.return (x + 1)

(* Using Lwt.Infix - this is OK *)
let example2 () =
  let open Lwt.Infix in
  Lwt.return () >>= fun () ->
  Lwt.return 42 >>= fun x ->
  Lwt.return (x + 1)

(* Explicit ignore_result - this is OK *)
let example3 () =
  Lwt.ignore_result (Lwt.return ())

(* Named binding (not ignored) - this is OK *)
let x : int Lwt.t = Lwt.return 42

(* Using the named binding *)
let () = Lwt_main.run (Lwt.map (fun _ -> ()) x)

(* Pattern matching (not wildcard) - this is OK *)
let example4 () =
  let (() : unit) = Lwt_main.run (Lwt.return ()) in
  ()

(* Nested in function bodies - all OK *)

(* let* inside function body *)
let nested_letstar () =
  let open Lwt.Syntax in
  let inner () =
    let* x = Lwt.return 10 in
    let* y = Lwt.return 20 in
    Lwt.return (x + y)
  in
  inner ()

(* Lwt.ignore_result inside function body *)
let nested_ignore_result () =
  let do_something () =
    Lwt.ignore_result (Lwt.return ());
    42
  in
  do_something ()

(* Named bindings inside function body *)
let nested_named_binding () =
  let promise : unit Lwt.t = Lwt.return () in
  Lwt_main.run promise

(* let* in match branch *)
let letstar_in_match x =
  let open Lwt.Syntax in
  match x with
  | true ->
      let* () = Lwt.return () in
      Lwt.return "yes"
  | false ->
      Lwt.return "no"

(* let* in if branch *)
let letstar_in_if condition =
  let open Lwt.Syntax in
  if condition then
    let* x = Lwt.return 1 in
    Lwt.return (x + 1)
  else
    Lwt.return 0

(* Multiple levels of nesting *)
let deeply_nested () =
  let open Lwt.Syntax in
  let level1 () =
    let level2 () =
      let level3 () =
        let* result = Lwt.return "deep" in
        Lwt.return result
      in
      level3 ()
    in
    level2 ()
  in
  level1 ()

let () = 
  let _ = example1 () in
  let _ = example2 () in
  let _ = example3 () in
  let _ = example4 () in
  let _ = nested_letstar () in
  let _ = nested_ignore_result () in
  let _ = nested_named_binding () in
  let _ = letstar_in_match true in
  let _ = letstar_in_if true in
  let _ = deeply_nested () in
  print_endline "All good patterns compiled successfully"
