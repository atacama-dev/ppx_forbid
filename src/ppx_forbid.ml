(******************************************************************************)
(*                                                                            *)
(* SPDX-License-Identifier: GPL-3.0-or-later                                               *)
(* Copyright (c) 2026 Mathias Bourgoin <mathias.bourgoin@atacama.tech>                                      *)
(*                                                                            *)
(******************************************************************************)

(** PPX rewriter that forbids specific function calls or modules at compile time.

    This PPX traverses the AST and raises compilation errors when forbidden
    functions or modules are used. Useful for enforcing coding standards like
    "use Eio instead of blocking Unix calls" or "never use Obj.magic".

    Usage: Add to dune file:
      (preprocess (pps ppx_forbid))

    Suppression: Use [@allow_forbidden "reason"] to suppress the check:
      let x = Unix.open_process_in cmd [@allow_forbidden "legacy code"]

    Configuration: Create a .ppx_forbid file in your project root with:
      # Forbid entire modules
      module Obj "Obj is unsafe and breaks type safety"

      # Forbid specific functions
      function Unix.open_process_in "Use Eio.Process instead"
      function Unix.sleep "Use Eio.Time.sleep"

    If no config file is found, a default set of rules is used. *)

open Ppxlib

(** Type of forbidden item *)
type forbidden_item =
  | Module of string * string  (** Entire module is forbidden, with reason *)
  | Function of string * string * string
      (** Specific function: (module, function, suggestion) *)

(** Default forbidden items (used when no config file found) *)
let default_forbidden : forbidden_item list =
  [
    (* === Forbidden modules === *)
    Module ("Obj", "Obj is unsafe and breaks type safety");
  ]

(** Parse a config line. Returns None for comments/empty lines. *)
let parse_config_line line =
  let line = String.trim line in
  if String.length line = 0 || line.[0] = '#' then None
  else
    (* Split on first space to get command *)
    match String.index_opt line ' ' with
    | None -> None
    | Some idx -> (
        let cmd = String.sub line 0 idx in
        let rest =
          String.trim (String.sub line (idx + 1) (String.length line - idx - 1))
        in
        match cmd with
        | "module" -> (
            (* module Name "reason" *)
            match String.index_opt rest ' ' with
            | None -> None
            | Some idx2 ->
                let name = String.sub rest 0 idx2 in
                let reason =
                  String.trim
                    (String.sub rest (idx2 + 1) (String.length rest - idx2 - 1))
                in
                (* Remove quotes if present *)
                let reason =
                  if String.length reason >= 2 && reason.[0] = '"' then
                    String.sub reason 1 (String.length reason - 2)
                  else reason
                in
                Some (Module (name, reason)))
        | "function" -> (
            (* function Module.func "suggestion" *)
            match String.index_opt rest ' ' with
            | None -> None
            | Some idx2 -> (
                let path = String.sub rest 0 idx2 in
                let suggestion =
                  String.trim
                    (String.sub rest (idx2 + 1) (String.length rest - idx2 - 1))
                in
                (* Remove quotes if present *)
                let suggestion =
                  if String.length suggestion >= 2 && suggestion.[0] = '"' then
                    String.sub suggestion 1 (String.length suggestion - 2)
                  else suggestion
                in
                (* Split path on last dot *)
                match String.rindex_opt path '.' with
                | None -> None
                | Some dot_idx ->
                    let modname = String.sub path 0 dot_idx in
                    let fname =
                      String.sub
                        path
                        (dot_idx + 1)
                        (String.length path - dot_idx - 1)
                    in
                    Some (Function (modname, fname, suggestion))))
        | _ -> None)

(** Load config from .ppx_forbid file, falling back to defaults *)
let load_config () =
  (* Try to find .ppx_forbid in current dir or parents *)
  let rec find_config dir =
    let path = Filename.concat dir ".ppx_forbid" in
    if Sys.file_exists path then Some path
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else find_config parent
  in
  match find_config (Sys.getcwd ()) with
  | None -> default_forbidden
  | Some path ->
      let ic = open_in path in
      let rec read_lines acc =
        match input_line ic with
        | line ->
            let acc' =
              match parse_config_line line with
              | Some item -> item :: acc
              | None -> acc
            in
            read_lines acc'
        | exception End_of_file ->
            close_in ic ;
            List.rev acc
      in
      let items = read_lines [] in
      if items = [] then default_forbidden else items

(** Cached config - loaded once per compilation *)
let forbidden = lazy (load_config ())

(** Check if attributes contain [@allow_forbidden] *)
let has_allow_forbidden attrs =
  List.exists
    (fun attr -> String.equal attr.attr_name.txt "allow_forbidden")
    attrs

(** Check if a Longident matches a forbidden item *)
let check_forbidden loc (lid : Longident.t) =
  let rec get_module_path = function
    | Longident.Lident s -> (None, s)
    | Longident.Ldot (t, s) -> (
        match get_module_path t with
        | None, m -> (Some m, s)
        | Some p, m -> (Some (p ^ "." ^ m), s))
    | Longident.Lapply _ -> (None, "")
  in
  let module_path, name = get_module_path lid in
  let forbidden_items = Lazy.force forbidden in
  (* Check against forbidden list *)
  List.iter
    (fun item ->
      match (item, module_path) with
      | Module (forbidden_mod, reason), Some m when m = forbidden_mod ->
          Location.raise_errorf
            ~loc
            "Forbidden module: %s is not allowed.@.Reason: %s@.Use \
             [@allow_forbidden \"reason\"] to suppress."
            forbidden_mod
            reason
      | Module (forbidden_mod, reason), None when name = forbidden_mod ->
          (* Direct module reference like "open Obj" *)
          Location.raise_errorf
            ~loc
            "Forbidden module: %s is not allowed.@.Reason: %s@.Use \
             [@allow_forbidden \"reason\"] to suppress."
            forbidden_mod
            reason
      | Function (modname, fname, suggestion), Some m
        when m = modname && name = fname ->
          Location.raise_errorf
            ~loc
            "Forbidden call: %s.%s is not allowed.@.Suggestion: %s@.Use \
             [@allow_forbidden \"reason\"] to suppress."
            modname
            fname
            suggestion
      | _ -> ())
    forbidden_items

(** AST traversal that checks all expressions and module expressions.
    Uses a mutable flag to track when we're inside an allowed region. *)
let checker =
  object (self)
    inherit Ast_traverse.iter as super

    val mutable allow_stack = 0

    method private with_allow f =
      allow_stack <- allow_stack + 1 ;
      f () ;
      allow_stack <- allow_stack - 1

    method private is_allowed = allow_stack > 0

    method! expression expr =
      (* Check if this expression has [@allow_forbidden] *)
      if has_allow_forbidden expr.pexp_attributes then
        self#with_allow (fun () -> super#expression expr)
      else (
        (if not self#is_allowed then
           match expr.pexp_desc with
           | Pexp_ident {txt; loc} -> check_forbidden loc txt
           | _ -> ()) ;
        super#expression expr)

    method! module_expr mexpr =
      if has_allow_forbidden mexpr.pmod_attributes then
        self#with_allow (fun () -> super#module_expr mexpr)
      else (
        (if not self#is_allowed then
           match mexpr.pmod_desc with
           | Pmod_ident {txt; loc} -> check_forbidden loc txt
           | _ -> ()) ;
        super#module_expr mexpr)

    method! open_declaration od =
      if has_allow_forbidden od.popen_attributes then
        self#with_allow (fun () -> super#open_declaration od)
      else (
        (if not self#is_allowed then
           match od.popen_expr.pmod_desc with
           | Pmod_ident {txt; loc} -> check_forbidden loc txt
           | _ -> ()) ;
        super#open_declaration od)

    method! value_binding vb =
      (* If the binding has the attribute, allow everything inside *)
      if has_allow_forbidden vb.pvb_attributes then
        self#with_allow (fun () -> super#value_binding vb)
      else super#value_binding vb
  end

(** The PPX driver entry point *)
let impl str =
  checker#structure str ;
  str

let () = Driver.register_transformation ~impl "ppx_forbid"
