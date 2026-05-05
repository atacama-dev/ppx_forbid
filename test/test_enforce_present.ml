(******************************************************************************)
(*                                                                            *)
(* SPDX-License-Identifier: GPL-3.0-or-later                                 *)
(* Copyright (c) 2026 Mathias Bourgoin <mathias.bourgoin@atacama.tech>        *)
(*                                                                            *)
(******************************************************************************)

(** Test that ppx_enforce passes when the required call IS present. *)

(* This file is compiled with --config pointing to test_enforce.ppx_enforce,
   which requires a call to Registry.register.
   Since we make the call below, it should compile successfully. *)

module Registry = struct
  let register ~name:_ ~mli:_ () = ()
end

let () = Registry.register ~name:"test" ~mli:"val x : int" ()
let () = print_endline "ppx_enforce present-call test passed"
