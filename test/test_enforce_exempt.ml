(******************************************************************************)
(*                                                                            *)
(* SPDX-License-Identifier: GPL-3.0-or-later                                 *)
(* Copyright (c) 2026 Mathias Bourgoin <mathias.bourgoin@atacama.tech>        *)
(*                                                                            *)
(******************************************************************************)

(** Test that [@@@enforce_exempt] suppresses the check even when the required
    call is absent. *)

[@@@enforce_exempt]

(* No Registry.register call here — should still compile because of the
   file-level exemption above. *)

let () = print_endline "ppx_enforce exempt test passed"
