open Yojson.Safe.Util

let a () = Exec.run ()
let b () = Exec.exact ()
let c j = Yojson.Safe.Util.member "k" j [@allow_forbidden "test"]
