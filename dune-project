(lang dune 3.13)
(name ppx_forbid)
(generate_opam_files true)

(package
 (name ppx_forbid)
 (synopsis "PPX that forbids specific function calls or modules at compile time")
 (description
   "A configurable PPX rewriter that traverses the AST and raises compilation 
errors when forbidden functions or modules are used. Useful for enforcing 
coding standards like 'use Eio instead of blocking Unix calls' or 
'never use Obj.magic'. Supports per-project configuration via .ppx_forbid 
files and [@allow_forbidden] attributes for suppression.")
 (depends
  (ocaml (>= 4.14))
  (ppxlib (>= 0.28.0)))
 (tags (ppx lint static-analysis))
 (license GPL-3.0-or-later)
 (authors "Mathias Bourgoin")
 (maintainers "mathias.bourgoin@atacama.tech")
 (homepage "https://github.com/atacama-dev/ppx_forbid")
 (bug_reports "https://github.com/atacama-dev/ppx_forbid/issues")
 (documentation "https://github.com/atacama-dev/ppx_forbid"))
