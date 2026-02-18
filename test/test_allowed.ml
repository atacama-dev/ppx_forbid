(******************************************************************************)
(*                                                                            *)
(* SPDX-License-Identifier: GPL-3.0-or-later                                               *)
(* Copyright (c) 2026 Mathias Bourgoin <mathias.bourgoin@atacama.tech>        *)
(*                                                                            *)
(******************************************************************************)

(** Test that [@allow_forbidden] suppresses the check *)

(* This should compile because of the suppression attribute on expression *)
let _magic_allowed =
  (Obj.magic 42 : string) [@allow_forbidden "test: verifying suppression works"]

(* Suppression on the entire expression *)
let _process_allowed =
 (fun cmd ->
  Unix.open_process_in cmd)
  [@allow_forbidden "test: legacy code wrapper"]

let () = print_endline "ppx_forbid suppression test passed"
