let f j = Yojson.Safe.Util.member "k" j [@allow_forbidden "test: expression"]
let[@allow_forbidden "test: binding"] g j = Yojson.Safe.Util.to_string j
