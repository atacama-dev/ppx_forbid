(******************************************************************************)
(*                                                                            *)
(* SPDX-License-Identifier: GPL-3.0-or-later                                               *)
(* Copyright (c) 2026 Mathias Bourgoin <mathias.bourgoin@atacama.tech>        *)
(*                                                                            *)
(******************************************************************************)

(** Test that [@allow_forbidden] suppression works for unresolved Lwt.t *)

(* Top-level suppressions *)

(* Suppression on expression - should compile *)
let _ : unit Lwt.t = 
  Lwt.return () [@allow_forbidden "test: intentionally ignoring for demo"]

(* Suppression on binding - should compile *)
let[@allow_forbidden "test: legacy fire-and-forget pattern"] 
  _fire_and_forget : int Lwt.t =
  Lwt.return 42

(* Nested suppressions *)

(* Suppression in function body with expression attribute *)
let suppressed_in_function () =
  let _ : unit Lwt.t = 
    Lwt.return () [@allow_forbidden "test: suppressed in function"] 
  in
  42

(* Suppression in function body with binding attribute *)
let suppressed_binding_in_function () =
  let[@allow_forbidden "test: needed for backwards compatibility"]
    _ignored : int Lwt.t = Lwt.return 10
  in
  "ok"

(* Suppression in nested function *)
let outer_with_suppression () =
  let inner () =
    let _ : string Lwt.t =
      Lwt.return "nested" [@allow_forbidden "test: deeply nested suppression"]
    in
    ()
  in
  inner ()

(* Suppression in match branch *)
let suppression_in_match x =
  match x with
  | true ->
      let _ : unit Lwt.t = 
        Lwt.return () [@allow_forbidden "test: branch-specific suppression"]
      in
      1
  | false -> 0

(* Suppression in if branch *)
let suppression_in_if condition =
  if condition then
    let[@allow_forbidden "test: conditional suppression"]
      _result : int Lwt.t = Lwt.return 42
    in
    true
  else
    false

(* Multiple suppressions in same scope *)
let multiple_suppressions () =
  let _ : unit Lwt.t = 
    Lwt.return () [@allow_forbidden "test: first suppression"]
  in
  let[@allow_forbidden "test: second suppression"]
    _x : int Lwt.t = Lwt.return 1
  in
  let _ : string Lwt.t =
    Lwt.return "test" [@allow_forbidden "test: third suppression"]
  in
  ()

let () = 
  let _ = suppressed_in_function () in
  let _ = suppressed_binding_in_function () in
  let _ = outer_with_suppression () in
  let _ = suppression_in_match true in
  let _ = suppression_in_if true in
  let _ = multiple_suppressions () in
  print_endline "Suppression with [@allow_forbidden] works correctly"
