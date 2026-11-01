(* Unit tests of the path and module-path helpers. *)
open Ppx_forbid

let check name cond =
  if not cond then (
    prerr_endline ("test_paths: " ^ name);
    exit 1)

(* A config at a project root (next to dune-project, with no dune-project
   above it) scopes a source in a sub-directory. The project is created in the
   temporary directory, outside this repository. *)
let root_config_scopes_a_subdirectory () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "ppx_forbid_rootcfg_%d" (Unix.getpid ()))
  in
  let write path text =
    let oc = open_out path in
    output_string oc text;
    close_out oc
  in
  List.iter
    (fun d -> if not (Sys.file_exists d) then Unix.mkdir d 0o755)
    [ root; Filename.concat root "lib" ];
  write (Filename.concat root "dune-project") "(lang dune 3.13)\n";
  let cfg = Filename.concat root ".ppx_forbid" in
  write cfg "module Exec \"x\"\nonly Exec lib/async_*.ml\n";
  let config = check_config cfg (load_config_file ~visited:[] cfg) in
  let applies file =
    source_file := to_source (Filename.concat root file);
    applicability config "Exec"
  in
  check "root config applies to lib/async_a.ml"
    (applies "lib/async_a.ml" = Applies);
  check "root config skips lib/plain.ml" (applies "lib/plain.ml" = Out_of_scope);
  check "root config skips async_a.ml at the root"
    (applies "async_a.ml" = Out_of_scope);
  List.iter Sys.remove [ cfg; Filename.concat root "dune-project" ];
  Unix.rmdir (Filename.concat root "lib");
  Unix.rmdir root

(* Inside dune, a sandboxed action under any build directory and any context
   name maps back to DUNE_SOURCEROOT. Runs last: it sets the environment. *)
let dune_sandbox_maps_to_the_source_tree () =
  Unix.putenv "DUNE_SOURCEROOT" "/src/proj";
  Unix.putenv "INSIDE_DUNE" "/ext/build/alt";
  check "context dir"
    (to_source "/ext/build/alt/lib/a.ml" = "/src/proj/lib/a.ml");
  check "sandbox of the context"
    (to_source "/ext/build/.sandbox/0f3a/alt/lib/a.ml" = "/src/proj/lib/a.ml");
  check "sandbox of another context is not mapped"
    (to_source "/ext/build/.sandbox/0f3a/other/lib/a.ml"
    = "/ext/build/.sandbox/0f3a/other/lib/a.ml");
  check "source path unchanged"
    (to_source "/src/proj/lib/a.ml" = "/src/proj/lib/a.ml")

(* A config reached through a symlink scopes a source given by its physical
   path. *)
let symlinked_config_matches_the_physical_source () =
  let tmp = Filename.get_temp_dir_name () in
  let real =
    Filename.concat tmp (Printf.sprintf "ppx_forbid_real_%d" (Unix.getpid ()))
  in
  let link =
    Filename.concat tmp (Printf.sprintf "ppx_forbid_link_%d" (Unix.getpid ()))
  in
  let cleanup () =
    (try Sys.remove (Filename.concat real ".ppx_forbid")
     with Sys_error _ -> ());
    (try Unix.unlink link with Unix.Unix_error _ -> ());
    (try Unix.rmdir (Filename.concat real "lib") with Unix.Unix_error _ -> ());
    try Unix.rmdir real with Unix.Unix_error _ -> ()
  in
  Fun.protect ~finally:cleanup (fun () ->
      Unix.mkdir real 0o755;
      Unix.mkdir (Filename.concat real "lib") 0o755;
      Unix.symlink real link;
      let oc = open_out (Filename.concat real ".ppx_forbid") in
      output_string oc "module Exec \"x\"\nonly Exec lib/async_*.ml\n";
      close_out oc;
      let cfg = Filename.concat link ".ppx_forbid" in
      let config = check_config cfg (load_config_file ~visited:[] cfg) in
      source_file := to_source (Filename.concat real "lib/async_a.ml");
      check "symlinked config applies" (applicability config "Exec" = Applies))

(* A build directory reached through a symlink: INSIDE_DUNE keeps the logical
   spelling while the action's path is physical. Runs last: sets the env. *)
let symlinked_build_dir_maps_to_the_source_tree () =
  let tmp = Filename.get_temp_dir_name () in
  let pid = Unix.getpid () in
  let real = Filename.concat tmp (Printf.sprintf "ppx_forbid_bigdisk_%d" pid) in
  let link =
    Filename.concat tmp (Printf.sprintf "ppx_forbid_buildlink_%d" pid)
  in
  let ctx = Filename.concat real "default" in
  let cleanup () =
    (try Unix.unlink link with Unix.Unix_error _ -> ());
    (try Unix.rmdir ctx with Unix.Unix_error _ -> ());
    try Unix.rmdir real with Unix.Unix_error _ -> ()
  in
  Fun.protect ~finally:cleanup (fun () ->
      Unix.mkdir real 0o755;
      Unix.mkdir ctx 0o755;
      Unix.symlink real link;
      Unix.putenv "DUNE_SOURCEROOT" "/src/proj";
      Unix.putenv "INSIDE_DUNE" (Filename.concat link "default");
      let physical = physical_dir real in
      check "symlinked context"
        (to_source (physical ^ "/default/lib/a.ml") = "/src/proj/lib/a.ml");
      check "symlinked context sandbox"
        (to_source (physical ^ "/.sandbox/h/default/lib/a.ml")
        = "/src/proj/lib/a.ml"))

(* A real source root may itself be cloned below another project's _build.
   The active Dune context still takes precedence over source membership. *)
let nested_source_root_keeps_source_paths () =
  let root = "/p/_build/scratch/ca-source" in
  Unix.putenv "DUNE_SOURCEROOT" root;
  Unix.putenv "INSIDE_DUNE" "/p/_build/scratch/ca-build/default";
  check "nested source file unchanged"
    (to_source (root ^ "/lib/a.ml") = root ^ "/lib/a.ml");
  check "nested source root unchanged" (to_source root = root);
  check "nested source external context"
    (to_source "/p/_build/scratch/ca-build/default/lib/a.ml"
    = root ^ "/lib/a.ml");
  check "nested source external sandbox"
    (to_source "/p/_build/scratch/ca-build/.sandbox/h/default/lib/a.ml"
    = root ^ "/lib/a.ml");
  check "source root boundary keeps legacy fallback"
    (to_source (root ^ "-other/lib/a.ml") = root ^ "/ca-source-other/lib/a.ml");
  Unix.putenv "INSIDE_DUNE" (root ^ "/_build/default");
  check "context inside source root still maps"
    (to_source (root ^ "/_build/default/lib/a.ml") = root ^ "/lib/a.ml");
  check "sandbox inside source root still maps"
    (to_source (root ^ "/_build/.sandbox/h/default/lib/a.ml")
    = root ^ "/lib/a.ml");
  Unix.putenv "DUNE_SOURCEROOT" "";
  Unix.putenv "INSIDE_DUNE" "";
  check "standalone fallback still maps"
    (to_source "/p/_build/default/lib/a.ml" = "/p/lib/a.ml")

let symlinked_nested_source_root_keeps_source_paths () =
  let tmp =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "ppx_forbid_nested_%d" (Unix.getpid ()))
  in
  let build = Filename.concat tmp "_build" in
  let source = Filename.concat build "source" in
  let lib = Filename.concat source "lib" in
  let link = Filename.concat tmp "source-link" in
  let dirs = [ tmp; build; source; lib ] in
  List.iter (fun d -> Unix.mkdir d 0o755) dirs;
  Fun.protect
    ~finally:(fun () ->
      (try Unix.unlink link with Unix.Unix_error _ -> ());
      List.iter Unix.rmdir (List.rev dirs))
    (fun () ->
      Unix.symlink source link;
      Unix.putenv "DUNE_SOURCEROOT" link;
      Unix.putenv "INSIDE_DUNE" (Filename.concat tmp "external/default");
      let expected = Filename.concat (physical_dir source) "lib/a.ml" in
      check "physical nested source unchanged"
        (to_source (Filename.concat source "lib/a.ml") = expected);
      check "symlinked nested source unchanged"
        (to_source (Filename.concat link "lib/a.ml") = expected))

let () =
  check "build context"
    (strip_build_prefix "/p/_build/default/lib/a.ml" = Some ("/p", "lib/a.ml"));
  check "sandbox"
    (strip_build_prefix "/p/_build/.sandbox/abc/default/lib/a.ml"
    = Some ("/p", "lib/a.ml"));
  check "named context"
    (strip_build_prefix "/p/_build/alt/lib/a.ml" = Some ("/p", "lib/a.ml"));
  check "named context sandbox"
    (strip_build_prefix "/p/_build/.sandbox/h/alt/lib/a.ml"
    = Some ("/p", "lib/a.ml"));
  check "a default segment outside _build is not a context"
    (strip_build_prefix "/home/u/default/proj/src/x.ml" = None);
  check "no build" (strip_build_prefix "/p/src/x.ml" = None);
  check "glob star" (glob_match "/p/lib/async_*.ml" "/p/lib/async_a.ml");
  check "glob star stops at slash"
    (not (glob_match "/p/lib/*.ml" "/p/lib/sub/a.ml"));
  check "glob question" (glob_match "/p/a?.ml" "/p/ab.ml");
  check "glob exact" (not (glob_match "/p/a.ml" "/p/b.ml"));
  check "normalize" (normalize "/p/./lib/../src//x.ml" = "/p/src/x.ml");
  check "canonical stdlib" (canonical "Stdlib.Obj" = "Obj");
  check "canonical mangled" (canonical "Stdlib__Obj" = "Obj");
  check "canonical dune lib" (canonical "Lib__Mod.Sub" = "Lib.Mod.Sub");
  check "canonical keeps plain"
    (canonical "Yojson.Safe.Util" = "Yojson.Safe.Util");
  check "within" (within "M" "M.Sub" && within "M" "M");
  check "within boundary" ((not (within "M" "Mx")) && not (within "M" "M2.x"));
  root_config_scopes_a_subdirectory ();
  symlinked_config_matches_the_physical_source ();
  dune_sandbox_maps_to_the_source_tree ();
  symlinked_build_dir_maps_to_the_source_tree ();
  nested_source_root_keeps_source_paths ();
  symlinked_nested_source_root_keeps_source_paths ();
  print_endline "test_paths: ok"
