(******************************************************************************)
(*                                                                            *)
(* SPDX-License-Identifier: GPL-3.0-or-later                                               *)
(* Copyright (c) 2026 Mathias Bourgoin <mathias.bourgoin@atacama.tech>        *)
(*                                                                            *)
(******************************************************************************)

(** Test that [@allow_forbidden] suppression works for unresolved Lwt.t *)

(* Suppression on expression - should compile *)
let _ : unit Lwt.t = 
  Lwt.return () [@allow_forbidden "test: intentionally ignoring for demo"]

(* Suppression on binding - should compile *)
let[@allow_forbidden "test: legacy fire-and-forget pattern"] 
  _fire_and_forget : int Lwt.t =
  Lwt.return 42

let () = print_endline "Suppression with [@allow_forbidden] works correctly"
