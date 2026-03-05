(******************************************************************************)
(*                                                                            *)
(* SPDX-License-Identifier: GPL-3.0-or-later                                               *)
(* Copyright (c) 2026 Mathias Bourgoin <mathias.bourgoin@atacama.tech>        *)
(*                                                                            *)
(******************************************************************************)

(** Test that unresolved Lwt.t bindings are caught *)

(* This should fail: wildcard pattern with Lwt.t type *)
let _ : unit Lwt.t = Lwt.return ()

(* This should fail: ignored variable with Lwt.t type *)
let _ignored : int Lwt.t = Lwt.return 42

(* This should fail: another ignored pattern *)
let _unused : string Lwt.t = Lwt.return "hello"
