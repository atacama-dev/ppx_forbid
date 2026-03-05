(******************************************************************************)
(*                                                                            *)
(* SPDX-License-Identifier: GPL-3.0-or-later                                               *)
(* Copyright (c) 2026 Mathias Bourgoin <mathias.bourgoin@atacama.tech>        *)
(*                                                                            *)
(******************************************************************************)

(** Test that properly resolved Lwt.t bindings are allowed *)

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

let () = 
  let _ = example1 () in
  let _ = example2 () in
  let _ = example3 () in
  let _ = example4 () in
  print_endline "All good patterns compiled successfully"
