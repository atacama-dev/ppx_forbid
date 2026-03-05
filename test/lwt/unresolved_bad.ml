(******************************************************************************)
(*                                                                            *)
(* SPDX-License-Identifier: GPL-3.0-or-later                                               *)
(* Copyright (c) 2026 Mathias Bourgoin <mathias.bourgoin@atacama.tech>        *)
(*                                                                            *)
(******************************************************************************)

(** Test that unresolved Lwt.t bindings are caught *)

(* Top-level bindings *)

(* This should fail: wildcard pattern with Lwt.t type *)
let _ : unit Lwt.t = Lwt.return ()

(* This should fail: ignored variable with Lwt.t type *)
let _ignored : int Lwt.t = Lwt.return 42

(* This should fail: another ignored pattern *)
let _unused : string Lwt.t = Lwt.return "hello"

(* Inside function bodies *)

(* This should fail: ignored in function body *)
let test_function () =
  let _ : unit Lwt.t = Lwt.return () in
  42

(* This should fail: ignored in nested function *)
let outer_function () =
  let inner_function () =
    let _ignored : int Lwt.t = Lwt.return 10 in
    "result"
  in
  inner_function ()

(* This should fail: multiple ignored in same function *)
let multiple_ignored () =
  let _ : unit Lwt.t = Lwt.return () in
  let _x : int Lwt.t = Lwt.return 1 in
  let _y : string Lwt.t = Lwt.return "test" in
  ()

(* This should fail: ignored in let...in expression *)
let with_let_in =
  let outer = 42 in
  let _ : unit Lwt.t = Lwt.return () in
  outer + 1

(* This should fail: ignored in match branch *)
let in_match_branch x =
  match x with
  | true -> 
      let _ : unit Lwt.t = Lwt.return () in
      "yes"
  | false -> "no"

(* This should fail: ignored in if branch *)
let in_if_branch condition =
  if condition then (
    let _ignored : unit Lwt.t = Lwt.return () in
    1
  ) else 2
