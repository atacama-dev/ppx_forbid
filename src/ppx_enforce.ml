(******************************************************************************)
(*                                                                            *)
(* SPDX-License-Identifier: GPL-3.0-or-later                                 *)
(* Copyright (c) 2026 Mathias Bourgoin <mathias.bourgoin@atacama.tech>        *)
(*                                                                            *)
(******************************************************************************)

(** PPX rewriter that enforces the presence of specific function calls at
    compile time.  The mirror of [ppx_forbid]: raises a compilation error when
    a required call is *absent* from a source file.

    Usage: Add to dune file:
      (preprocess (pps ppx_enforce))

    Suppression: Add [[@@@enforce_exempt]] at the top of a file to skip all
    enforcement checks for that file:
      [@@@enforce_exempt]   (* this file is intentionally exempt *)

    Or exempt a specific requirement:
      [@@@enforce_exempt "Miaou_registry.register"]

    Configuration: Create a .ppx_enforce file in your project root with:
      # Enforce that Miaou_registry.register is called somewhere in the file
      call Miaou_registry.register "Widget must self-register via Miaou_registry.register ~name ~mli:[%blob ...]"

    If no config file is found, no requirements are enforced. *)

open Ppxlib

(** A single enforcement requirement. *)
type required_item =
  | Call of string * string * string
      (** [Call (module_name, function_name, message)] — the file must contain
          at least one reference to [Module_name.function_name]. *)

(** Config file path override (set via --config flag) *)
let config_path_override = ref None

(** Parse a config line. Returns None for comments/empty lines. *)
let parse_config_line line =
  let line = String.trim line in
  if String.length line = 0 || line.[0] = '#' then None
  else
    match String.index_opt line ' ' with
    | None -> None
    | Some idx ->
        let cmd = String.sub line 0 idx in
        let rest =
          String.trim (String.sub line (idx + 1) (String.length line - idx - 1))
        in
        (match cmd with
        | "call" ->
            (* call Module.function "message" *)
            (match String.index_opt rest ' ' with
            | None -> None
            | Some idx2 ->
                let path = String.sub rest 0 idx2 in
                let message =
                  String.trim
                    (String.sub rest (idx2 + 1) (String.length rest - idx2 - 1))
                in
                let message =
                  if String.length message >= 2 && message.[0] = '"' then
                    String.sub message 1 (String.length message - 2)
                  else message
                in
                (match String.rindex_opt path '.' with
                | None -> None
                | Some dot ->
                    let modname = String.sub path 0 dot in
                    let fname =
                      String.sub path (dot + 1) (String.length path - dot - 1)
                    in
                    Some (Call (modname, fname, message))))
        | _ -> None)

(** Load config from a file. *)
let load_config_file path =
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    let rec read_lines acc =
      match input_line ic with
      | line -> (
          match parse_config_line line with
          | Some item -> read_lines (item :: acc)
          | None -> read_lines acc)
      | exception End_of_file ->
          close_in ic ;
          List.rev acc
    in
    read_lines []

(** Find config file by walking up directory tree. *)
let rec find_config_file dir =
  let path = Filename.concat dir ".ppx_enforce" in
  if Sys.file_exists path then Some path
  else
    let parent = Filename.dirname dir in
    if parent = dir then None else find_config_file parent

let source_dir = ref None

let load_config () =
  let path =
    match !config_path_override with
    | Some p -> Some p
    | None ->
        let start_dir =
          match !source_dir with Some d -> d | None -> Sys.getcwd ()
        in
        find_config_file start_dir
  in
  match path with None -> [] | Some p -> load_config_file p

let required_items = ref None

let get_required () =
  match !required_items with
  | Some items -> items
  | None ->
      let items = load_config () in
      required_items := Some items ;
      items

(** Strip dune sandbox/build prefix to get source path. *)
let strip_build_prefix path =
  match String.split_on_char '/' path with
  | parts ->
      let rec find_default = function
        | [] -> None
        | "default" :: rest -> Some rest
        | _ :: rest -> find_default rest
      in
      (match find_default parts with
      | Some rest -> Some (String.concat "/" rest)
      | None -> None)

(** Check for [@@@enforce_exempt] or [@@@enforce_exempt "Mod.fn"] attributes
    at the structure level. Returns:
    - `All    → file is fully exempt
    - `Some s → only the named requirement is exempt
    Returns a list of exemptions. *)
let collect_exemptions str =
  List.filter_map
    (fun item ->
      match item.pstr_desc with
      | Pstr_attribute attr
        when String.equal attr.attr_name.txt "enforce_exempt" ->
          (match attr.attr_payload with
          | PStr [] -> Some `All
          | PStr
              [
                {
                  pstr_desc =
                    Pstr_eval
                      ({pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _},
                      _);
                  _;
                };
              ] ->
              Some (`Named s)
          | _ -> Some `All)
      | _ -> None)
    str

(** Search the structure for any occurrence of [Modname.fname]. *)
let contains_call str modname fname =
  let found = ref false in
  let searcher =
    object
      inherit Ast_traverse.iter as super

      method! expression expr =
        (match expr.pexp_desc with
        | Pexp_ident {txt; _} -> (
            match txt with
            | Longident.Ldot (Longident.Lident m, f)
              when String.equal m modname && String.equal f fname ->
                found := true
            | Longident.Ldot (outer, f) when String.equal f fname ->
                (* Handle qualified paths like A.B.fn *)
                let rec flatten = function
                  | Longident.Lident s -> s
                  | Longident.Ldot (t, s) -> flatten t ^ "." ^ s
                  | Longident.Lapply _ -> ""
                in
                if String.equal (flatten outer) modname then found := true
            | _ -> ())
        | _ -> ()) ;
        super#expression expr
    end
  in
  searcher#structure str ;
  !found

(** The PPX implementation: check that each required call is present. *)
let impl str =
  (* Set source directory from first item's location *)
  (match str with
  | {pstr_loc; _} :: _ when pstr_loc.loc_start.pos_fname <> "" ->
      let file = pstr_loc.loc_start.pos_fname in
      let file =
        if Filename.is_relative file then Filename.concat (Sys.getcwd ()) file
        else file
      in
      let file =
        match strip_build_prefix file with
        | Some relative ->
            let rec find_root dir =
              if Sys.file_exists (Filename.concat dir "dune-project") then
                Some dir
              else
                let parent = Filename.dirname dir in
                if parent = dir then None else find_root parent
            in
            (match find_root (Sys.getcwd ()) with
            | Some root -> Filename.concat root relative
            | None -> file)
        | None -> file
      in
      let dir = Filename.dirname file in
      if !source_dir <> Some dir then (
        source_dir := Some dir ;
        required_items := None)
  | _ -> ()) ;
  let items = get_required () in
  if items = [] then str
  else
    let exemptions = collect_exemptions str in
    let fully_exempt = List.mem `All exemptions in
    if fully_exempt then str
    else begin
      let exempt_names =
        List.filter_map
          (function `Named s -> Some s | `All -> None)
          exemptions
      in
      List.iter
        (fun (Call (modname, fname, message)) ->
          let key = modname ^ "." ^ fname in
          if List.mem key exempt_names then ()
          else if not (contains_call str modname fname) then begin
            let loc =
              match str with item :: _ -> item.pstr_loc | [] -> Location.none
            in
            Location.raise_errorf ~loc
              "Missing required call: %s.%s@.%s@.Use [@@@enforce_exempt \"%s\"] \
               to suppress for this file."
              modname fname message key
          end)
        items ;
      str
    end

let () =
  Driver.add_arg "--config"
    (Arg.String (fun s -> config_path_override := Some s))
    ~doc:"PATH Path to .ppx_enforce config file" ;
  Driver.register_transformation ~impl "ppx_enforce"
