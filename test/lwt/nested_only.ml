(******************************************************************************)
(*                                                                            *)
(* SPDX-License-Identifier: GPL-3.0-or-later                                               *)
(* Copyright (c) 2026 Mathias Bourgoin <mathias.bourgoin@atacama.tech>        *)
(*                                                                            *)
(******************************************************************************)

(** Test nested unresolved bindings only *)

(* This should fail: ignored in function body *)
let test_function () =
  let _ : unit Lwt.t = Lwt.return () in
  42
