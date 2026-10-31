(******************************************************************************)
(*                                                                            *)
(* SPDX-License-Identifier: GPL-3.0-or-later                                               *)
(* Copyright (c) 2026 Mathias Bourgoin <mathias.bourgoin@atacama.tech>        *)
(*                                                                            *)
(******************************************************************************)

(** PPX rewriter that forbids specific function calls or modules at compile
    time.

    This PPX traverses the AST and raises compilation errors when forbidden
    functions or modules are used. Useful for enforcing coding standards like
    "use Eio instead of blocking Unix calls" or "never use Obj.magic".

    Usage: Add to dune file: (preprocess (pps ppx_forbid))

    Or with a specific config: (preprocess (pps (ppx_forbid --config
    .ppx_forbid.tui)))

    Suppression: Use [@allow_forbidden "reason"] to suppress the check: let x =
    Unix.open_process_in cmd [@allow_forbidden "legacy code"]

    Configuration: Create a .ppx_forbid file in your project root with: #
    Include another config file (relative to this file's directory) include
    ../base.ppx_forbid

    # Forbid entire modules module Obj "Obj is unsafe and breaks type safety"

    # Forbid specific functions function Unix.open_process_in "Use Eio.Process
    instead" function Unix.sleep "Use Eio.Time.sleep"

    # Allow one function of a forbidden module allow Obj.repr

    # Scope a rule to some files, or exempt files from it (globs relative to
    this file's directory; [*] and [?] never cross a [/]) only Obj ffi_*.ml
    exempt Obj ffi_boundary.ml "FFI boundary"

    With [--report], violations are printed to stderr instead of failing, one
    per line, so a project can keep a shrink-only allowlist.

    If no config file is found, a default set of rules is used. A malformed or
    unknown config line, a missing included file and a missing [--config] file
    are errors. *)

open Ppxlib

(** Type of forbidden item *)
type forbidden_item =
  | Module of string * string  (** Entire module is forbidden, with reason *)
  | Function of string * string * string
      (** Specific function: (module, function, suggestion) *)

type scope_kind = Only | Exempt of string  (** reason *)

type scope = { target : string; kind : scope_kind; pattern : string }
(** Path scoping of one rule. [pattern] is an absolute source-tree glob: the
    declared glob resolved against the directory of the declaring config. *)

type config = {
  items : forbidden_item list;
  allows : string list;  (** [M.f] allowed inside a forbidden [module M] *)
  scopes : scope list;
}

let empty_config = { items = []; allows = []; scopes = [] }

(** Default forbidden items (used when no config file found) *)
let default_forbidden : forbidden_item list =
  [ Module ("Obj", "Obj is unsafe and breaks type safety") ]

let default_config = { empty_config with items = default_forbidden }

(** Config file path override (set via --config flag) *)
let config_path_override = ref None

(** Report mode (set via --report): print violations instead of failing *)
let report_mode = ref false

let config_error path line msg =
  failwith (Printf.sprintf "ppx_forbid: %s: %s: %S" path msg line)

(* ------------------------------------------------------------------------ *)
(* Paths                                                                     *)

(** Collapse [.] and [..] segments of a ['/']-separated path. *)
let normalize path =
  let absolute = String.length path > 0 && path.[0] = '/' in
  let parts =
    List.fold_left
      (fun acc seg ->
        match (seg, acc) with
        | ("" | "."), _ -> acc
        | "..", _ :: rest -> rest
        | "..", [] -> acc
        | seg, _ -> seg :: acc)
      []
      (String.split_on_char '/' path)
  in
  let joined = String.concat "/" (List.rev parts) in
  if absolute then "/" ^ joined else joined

(** The physical path of an existing directory (symlinks resolved), or [dir]. It
    changes the cwd for an instant and restores it, which is safe in the
    single-threaded ppx driver. *)
let physical_dir dir =
  let cwd = Sys.getcwd () in
  match Sys.chdir dir with
  | () -> Fun.protect ~finally:(fun () -> Sys.chdir cwd) Sys.getcwd
  | exception Sys_error _ -> dir

(** Absolute normalized path, with symlinks resolved in its directory part, so
    that a config path and a source path spelled through different symlinks
    still compare equal. *)
let absolute path =
  let abs =
    normalize
      (if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
       else path)
  in
  let is_dir d = Sys.file_exists d && Sys.is_directory d in
  if is_dir abs then normalize (physical_dir abs)
  else
    let dir = Filename.dirname abs in
    if is_dir dir then
      normalize (Filename.concat (physical_dir dir) (Filename.basename abs))
    else abs

(** [Some rest] when [path] is [dir] or lies below it *)
let below dir path =
  let dir = if dir = "/" then "/" else dir ^ "/" in
  let n = String.length dir in
  if String.length path >= n && String.sub path 0 n = dir then
    Some (String.sub path n (String.length path - n))
  else None

(** An absolute directory from the environment, symlinks resolved like file
    paths (a build directory may be reached through a symlink, while the cwd of
    an action is physical). *)
let getenv_path name =
  match Sys.getenv_opt name with
  | Some v when v <> "" && not (Filename.is_relative v) -> Some (absolute v)
  | _ -> None

let rec find_project_root dir =
  if Sys.file_exists (Filename.concat dir "dune-project") then Some dir
  else
    let parent = Filename.dirname dir in
    if parent = dir then None else find_project_root parent

(** Split an absolute build path at its dune build context, for use outside
    dune: the directory holding the [_build] segment, and the path below the
    build context ([_build/<context>/...] or
    [_build/.sandbox/<hash>/<context>/...], whatever the context name). Inside
    dune, [to_source] uses [INSIDE_DUNE] instead, which also covers a build
    directory not named [_build]. *)
let strip_build_prefix path =
  let rec scan before = function
    | [] -> None
    | "_build" :: ".sandbox" :: _ :: _ :: (_ :: _ as rest) ->
        Some (String.concat "/" (List.rev before), rest)
    | "_build" :: ctx :: (_ :: _ as rest) when ctx <> ".sandbox" ->
        Some (String.concat "/" (List.rev before), rest)
    | seg :: rest -> scan (seg :: before) rest
  in
  match scan [] (String.split_on_char '/' path) with
  | Some (root, rest) ->
      Some ((if root = "" then "/" else root), String.concat "/" rest)
  | None -> None

(** The source tree path of a file that may live in a dune build context. Inside
    dune, [INSIDE_DUNE] is the build context and [DUNE_SOURCEROOT] the source
    root; otherwise a [_build/.../default/] segment locates them. *)
let to_source path =
  let abs = absolute path in
  let source_root fallback =
    match getenv_path "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> fallback
  in
  let in_context =
    match getenv_path "INSIDE_DUNE" with
    | Some ctx -> (
        let in_sandbox () =
          (* Dune runs actions in <build>/.sandbox/<hash>/<context name>. *)
          match
            below (Filename.concat (Filename.dirname ctx) ".sandbox") abs
          with
          | Some rest -> (
              match String.split_on_char '/' rest with
              | _hash :: name :: (_ :: _ as below_ctx)
                when name = Filename.basename ctx ->
                  Some (String.concat "/" below_ctx)
              | _ -> None)
          | None -> None
        in
        match
          match below ctx abs with
          | Some rel -> Some rel
          | None -> in_sandbox ()
        with
        | Some rel ->
            let fallback =
              match find_project_root (Filename.dirname ctx) with
              | Some r -> r
              | None -> Filename.dirname ctx
            in
            Some (normalize (Filename.concat (source_root fallback) rel))
        | None -> None)
    | None -> None
  in
  match in_context with
  | Some p -> p
  | None -> (
      match strip_build_prefix abs with
      | Some (root, rel) -> normalize (Filename.concat (source_root root) rel)
      | None -> abs)

(** Glob match where [*] and [?] never match a ['/']. *)
let glob_match pattern text =
  let pl = String.length pattern and tl = String.length text in
  let rec go pi ti =
    if pi = pl then ti = tl
    else
      match pattern.[pi] with
      | '*' -> go (pi + 1) ti || (ti < tl && text.[ti] <> '/' && go pi (ti + 1))
      | '?' -> ti < tl && text.[ti] <> '/' && go (pi + 1) (ti + 1)
      | c -> ti < tl && text.[ti] = c && go (pi + 1) (ti + 1)
  in
  go 0 0

(* ------------------------------------------------------------------------ *)
(* Module paths                                                              *)

let rec path_of = function
  | Longident.Lident s -> Some s
  | Longident.Ldot (t, s) -> Option.map (fun p -> p ^ "." ^ s) (path_of t)
  | Longident.Lapply _ -> None

(** Canonical module path: dune-mangled [A__B] segments are split into [A.B],
    and a leading [Stdlib] is dropped, so [Stdlib.Obj] and [Stdlib__Obj] are
    [Obj]. *)
let canonical path =
  let split_mangled seg =
    let rec go acc start i =
      if i + 1 >= String.length seg then
        List.rev (String.sub seg start (String.length seg - start) :: acc)
      else if seg.[i] = '_' && seg.[i + 1] = '_' && i > start then
        go (String.sub seg start (i - start) :: acc) (i + 2) (i + 2)
      else go acc start (i + 1)
    in
    go [] 0 0
  in
  let segs =
    List.concat_map split_mangled (String.split_on_char '.' path)
    |> List.filter (fun s -> s <> "")
  in
  let segs =
    match segs with "Stdlib" :: (_ :: _ as rest) -> rest | segs -> segs
  in
  String.concat "." segs

(** [path] is [m] or lies inside it, on segment boundaries *)
let within m path =
  path = m
  || String.length path > String.length m
     && String.sub path 0 (String.length m) = m
     && path.[String.length m] = '.'

(** A module rule matches a path by its canonical form, or literally (so that a
    rule on [Stdlib] itself still matches [Stdlib.List]). *)
let module_matches m ~raw ~canon = within (canonical m) canon || within m raw

let target_of = function
  | Module (m, _) -> m
  | Function (m, f, _) -> m ^ "." ^ f

(* ------------------------------------------------------------------------ *)
(* Config                                                                    *)

let unquote s =
  if String.length s >= 2 && s.[0] = '"' && s.[String.length s - 1] = '"' then
    String.sub s 1 (String.length s - 2)
  else s

(** Split [s] on its first space: (head, trimmed rest) *)
let split_first s =
  match String.index_opt s ' ' with
  | None -> None
  | Some idx ->
      Some
        ( String.sub s 0 idx,
          String.trim (String.sub s (idx + 1) (String.length s - idx - 1)) )

let parse_module ~err rest =
  match split_first rest with
  | Some (name, reason) -> Module (name, unquote reason)
  | None -> err "module expects <Module> \"<reason>\""

let parse_function ~err rest =
  match split_first rest with
  | Some (fpath, suggestion) -> (
      match String.rindex_opt fpath '.' with
      | Some dot when dot > 0 && dot < String.length fpath - 1 ->
          Function
            ( String.sub fpath 0 dot,
              String.sub fpath (dot + 1) (String.length fpath - dot - 1),
              unquote suggestion )
      | _ -> err "function expects <Module.function> \"<suggestion>\"")
  | None -> err "function expects <Module.function> \"<suggestion>\""

let parse_scope ~err ~base_dir cmd rest =
  let pattern glob = normalize (Filename.concat (to_source base_dir) glob) in
  match (cmd, split_first rest) with
  | "only", Some (target, glob)
    when glob <> "" && not (String.contains glob ' ') ->
      { target; kind = Only; pattern = pattern glob }
  | "exempt", Some (target, more) -> (
      match split_first more with
      | Some (glob, reason) when unquote reason <> "" ->
          { target; kind = Exempt (unquote reason); pattern = pattern glob }
      | _ -> err "exempt expects <target> <path-glob> \"<reason>\"")
  | "only", _ -> err "only expects <target> <path-glob>"
  | _ -> err "exempt expects <target> <path-glob> \"<reason>\""

(** Parse a config line. Returns None for comments/empty lines; any malformed or
    unknown line is an error, so that a typo cannot drop a rule. *)
let parse_config_line ~path ~base_dir line =
  let line = String.trim line in
  let err msg = config_error path line msg in
  if String.length line = 0 || line.[0] = '#' then None
  else
    match split_first line with
    | None -> err "unknown or incomplete directive"
    | Some ("include", rest) ->
        let inc =
          if Filename.is_relative rest then Filename.concat base_dir rest
          else rest
        in
        if not (Sys.file_exists inc) then err "included file does not exist";
        Some (`Include inc)
    | Some ("module", rest) -> Some (`Item (parse_module ~err rest))
    | Some ("function", rest) -> Some (`Item (parse_function ~err rest))
    | Some ("allow", rest) ->
        if String.contains rest ' ' || not (String.contains rest '.') then
          err "allow expects one Module.function"
        else Some (`Allow rest)
    | Some ((("only" | "exempt") as cmd), rest) ->
        Some (`Scope (parse_scope ~err ~base_dir cmd rest))
    | Some _ -> err "unknown directive"

(** Load config from a file, recursively handling includes *)
let rec load_config_file ~visited path =
  if List.mem path visited then empty_config
  else
    let base_dir = Filename.dirname path in
    let ic = open_in path in
    let rec read acc =
      match input_line ic with
      | line -> (
          match parse_config_line ~path ~base_dir line with
          | Some (`Include inc_path) ->
              let inc = load_config_file ~visited:(path :: visited) inc_path in
              read
                {
                  items = acc.items @ inc.items;
                  allows = acc.allows @ inc.allows;
                  scopes = acc.scopes @ inc.scopes;
                }
          | Some (`Item item) -> read { acc with items = acc.items @ [ item ] }
          | Some (`Allow a) -> read { acc with allows = acc.allows @ [ a ] }
          | Some (`Scope s) -> read { acc with scopes = acc.scopes @ [ s ] }
          | None -> read acc)
      | exception End_of_file ->
          close_in ic;
          acc
      | exception e ->
          close_in_noerr ic;
          raise e
    in
    read empty_config

(** Every [allow], [only] and [exempt] must name a rule of the config. *)
let check_config path config =
  let fail fmt =
    Printf.ksprintf (fun m -> failwith ("ppx_forbid: " ^ path ^ ": " ^ m)) fmt
  in
  let targets = List.map target_of config.items in
  let modules =
    List.filter_map
      (function Module (m, _) -> Some m | _ -> None)
      config.items
  in
  List.iter
    (fun s ->
      if not (List.mem s.target targets) then
        fail "only/exempt names no rule: %s" s.target)
    config.scopes;
  List.iter
    (fun allowed ->
      match String.rindex_opt allowed '.' with
      | Some dot
        when List.exists (fun m -> within m (String.sub allowed 0 dot)) modules
        ->
          ()
      | _ -> fail "allow names no forbidden module: %s" allowed)
    config.allows;
  config

(** Find config file by walking up directory tree *)
let rec find_config_file dir =
  let path = Filename.concat dir ".ppx_forbid" in
  if Sys.file_exists path then Some path
  else
    let parent = Filename.dirname dir in
    if parent = dir then None else find_config_file parent

(** Source file, as an absolute source-tree path *)
let source_file = ref ""

(** Directory of the source file - where the config search starts *)
let source_dir = ref None

(** Load config - uses override if set, otherwise searches from source dir *)
let load_config () =
  let path =
    match !config_path_override with
    | Some p ->
        if not (Sys.file_exists p) then
          failwith
            (Printf.sprintf "ppx_forbid: --config file does not exist: %s" p);
        Some p
    | None ->
        let start_dir =
          match !source_dir with Some d -> d | None -> Sys.getcwd ()
        in
        find_config_file start_dir
  in
  match path with
  | None -> default_config
  | Some p ->
      let config = load_config_file ~visited:[] p in
      if config.items = [] && config.allows = [] && config.scopes = [] then
        default_config
      else check_config p config

(** Mutable config - reloaded when source file changes *)
let forbidden_config = ref None

let get_config () =
  match !forbidden_config with
  | Some c -> c
  | None ->
      let c = load_config () in
      forbidden_config := Some c;
      c

(* ------------------------------------------------------------------------ *)
(* Checks                                                                    *)

(** Check if attributes contain [@allow_forbidden] *)
let has_allow_forbidden attrs =
  List.exists
    (fun attr -> String.equal attr.attr_name.txt "allow_forbidden")
    attrs

(** How a rule applies to the current file *)
type applicability = Applies | Exempted | Out_of_scope

let applicability config target =
  let scopes = List.filter (fun s -> s.target = target) config.scopes in
  let only = List.filter (fun s -> s.kind = Only) scopes in
  let matches s = glob_match s.pattern !source_file in
  if only <> [] && not (List.exists matches only) then Out_of_scope
  else if List.exists (fun s -> s.kind <> Only && matches s) scopes then
    Exempted
  else Applies

let report loc status kind target =
  let pos = loc.loc_start in
  Printf.eprintf "%s:%d:%d: %s %s %s\n%!" pos.pos_fname pos.pos_lnum
    (pos.pos_cnum - pos.pos_bol)
    status kind target

(** Act on one matching rule: fail, or print it in report mode *)
let hit ~suppressed config loc item message =
  let kind =
    match item with Module _ -> "module" | Function _ -> "function"
  in
  let target = target_of item in
  match applicability config target with
  | Out_of_scope -> ()
  | Exempted -> if !report_mode then report loc "exempt" kind target
  | Applies ->
      if !report_mode then
        report loc
          (if suppressed then "suppressed" else "forbidden")
          kind target
      else if not suppressed then Location.raise_errorf ~loc "%s" message

let module_message m reason =
  Printf.sprintf
    "Forbidden module: %s is not allowed.\n\
     Reason: %s\n\
     Use [@allow_forbidden \"reason\"] to suppress."
    m reason

let function_message m f suggestion =
  Printf.sprintf
    "Forbidden call: %s.%s is not allowed.\n\
     Suggestion: %s\n\
     Use [@allow_forbidden \"reason\"] to suppress."
    m f suggestion

(** Check a module path (an open, alias, include, functor argument, module type,
    or the qualifier of a constructor, label or class): naming a forbidden
    module or a module inside it is forbidden. *)
let check_module_path ~suppressed loc path =
  let config = get_config () in
  let canon = canonical path in
  List.iter
    (function
      | Module (m, reason) as item when module_matches m ~raw:path ~canon ->
          hit ~suppressed config loc item (module_message m reason)
      | _ -> ())
    config.items

let check_module ~suppressed loc lid =
  Option.iter (check_module_path ~suppressed loc) (path_of lid)

(** Check the module qualifier of a constructor, label, class or module type *)
let check_qualifier ~suppressed loc = function
  | Longident.Ldot (t, _) -> check_module ~suppressed loc t
  | _ -> ()

(** Check a value identifier against the rules *)
let check_value ~suppressed loc (lid : Longident.t) =
  let config = get_config () in
  let raw_path, name =
    match lid with
    | Longident.Ldot (t, s) -> (path_of t, s)
    | Longident.Lident s -> (None, s)
    | Longident.Lapply _ -> (None, "")
  in
  let module_path = Option.map canonical raw_path in
  let raw = Option.value raw_path ~default:"" in
  List.iter
    (fun item ->
      match (item, module_path) with
      | Module (m, reason), Some p when module_matches m ~raw ~canon:p ->
          let qualified = p ^ "." ^ name in
          if not (List.exists (fun a -> canonical a = qualified) config.allows)
          then hit ~suppressed config loc item (module_message m reason)
      | Function (modname, fname, suggestion), Some p
        when p = canonical modname && name = fname ->
          hit ~suppressed config loc item
            (function_message modname fname suggestion)
      | Function (modname, fname, suggestion), None
        when modname = "Stdlib" && name = fname ->
          hit ~suppressed config loc item
            (function_message modname fname suggestion)
      | _ -> ())
    config.items

(** AST traversal. A mutable counter tracks [@allow_forbidden] regions: hits
    there are ignored, or printed as [suppressed] in report mode. *)
let checker =
  object (self)
    inherit Ast_traverse.iter as super
    val mutable allow_stack = 0

    method private with_allow f =
      allow_stack <- allow_stack + 1;
      f ();
      allow_stack <- allow_stack - 1

    method private visit attrs f =
      if has_allow_forbidden attrs then self#with_allow f else f ()

    method private active = allow_stack = 0 || !report_mode
    method private suppressed = allow_stack > 0

    method private value loc lid =
      if self#active then check_value ~suppressed:self#suppressed loc lid

    method private qualifier loc lid =
      if self#active then check_qualifier ~suppressed:self#suppressed loc lid

    method! expression expr =
      self#visit expr.pexp_attributes (fun () ->
          (match expr.pexp_desc with
          | Pexp_ident { txt; loc } -> self#value loc txt
          | Pexp_construct ({ txt; loc }, _)
          | Pexp_field (_, { txt; loc })
          | Pexp_setfield (_, { txt; loc }, _)
          | Pexp_new { txt; loc } ->
              self#qualifier loc txt
          | Pexp_record (fields, _) ->
              List.iter (fun ({ txt; loc }, _) -> self#qualifier loc txt) fields
          | _ -> ());
          super#expression expr)

    method! pattern pat =
      self#visit pat.ppat_attributes (fun () ->
          (match pat.ppat_desc with
          | Ppat_construct ({ txt; loc }, _) -> self#qualifier loc txt
          | Ppat_open ({ txt; loc }, _) ->
              if self#active then
                check_module ~suppressed:self#suppressed loc txt
          | Ppat_record (fields, _) ->
              List.iter (fun ({ txt; loc }, _) -> self#qualifier loc txt) fields
          | _ -> ());
          super#pattern pat)

    method! module_expr mexpr =
      self#visit mexpr.pmod_attributes (fun () ->
          (match mexpr.pmod_desc with
          | Pmod_ident { txt; loc } ->
              if self#active then
                check_module ~suppressed:self#suppressed loc txt
          | _ -> ());
          super#module_expr mexpr)

    method! module_type mty =
      self#visit mty.pmty_attributes (fun () ->
          (match mty.pmty_desc with
          | Pmty_ident { txt; loc } -> self#qualifier loc txt
          | Pmty_alias { txt; loc } ->
              if self#active then
                check_module ~suppressed:self#suppressed loc txt
          | _ -> ());
          super#module_type mty)

    method! class_expr cexpr =
      self#visit cexpr.pcl_attributes (fun () ->
          (match cexpr.pcl_desc with
          | Pcl_constr ({ txt; loc }, _) -> self#qualifier loc txt
          | _ -> ());
          super#class_expr cexpr)

    method! class_type cty =
      self#visit cty.pcty_attributes (fun () ->
          (match cty.pcty_desc with
          | Pcty_constr ({ txt; loc }, _) -> self#qualifier loc txt
          | _ -> ());
          super#class_type cty)

    method! open_description od =
      self#visit od.popen_attributes (fun () ->
          (if self#active then
             let { txt; loc } = od.popen_expr in
             check_module ~suppressed:self#suppressed loc txt);
          super#open_description od)

    method! extension_constructor ext =
      self#visit ext.pext_attributes (fun () ->
          (match ext.pext_kind with
          | Pext_rebind { txt; loc } -> self#qualifier loc txt
          | _ -> ());
          super#extension_constructor ext)

    method! open_declaration od =
      self#visit od.popen_attributes (fun () -> super#open_declaration od)

    method! value_binding vb =
      self#visit vb.pvb_attributes (fun () -> super#value_binding vb)
  end

(** The PPX driver entry point *)
let impl str =
  (match str with
  | { pstr_loc; _ } :: _ when pstr_loc.loc_start.pos_fname <> "" ->
      let file = to_source pstr_loc.loc_start.pos_fname in
      source_file := file;
      let dir = Filename.dirname file in
      (* Only update if different from current - avoids reloading config *)
      if !source_dir <> Some dir then (
        source_dir := Some dir;
        forbidden_config := None)
  | _ -> ());
  (* Load the config before traversal, so that a config error is reported even
     for a file with nothing to check. *)
  ignore (get_config ());
  checker#structure str;
  str

let () =
  Driver.add_arg "--config"
    (Arg.String (fun s -> config_path_override := Some s))
    ~doc:"PATH Path to .ppx_forbid config file";
  Driver.add_arg "--report" (Arg.Set report_mode)
    ~doc:
      " Print every violation to stderr (forbidden, suppressed or exempt) \
       instead of failing";
  Driver.register_transformation ~impl "ppx_forbid"
