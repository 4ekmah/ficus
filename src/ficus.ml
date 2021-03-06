(*
    This file is a part of ficus language project.
    See ficus/LICENSE for the licensing terms
*)

open Options

let () =
    let ok = parse_options() in
    if ok then
        ignore(Compiler.process_all options.filename)
    else ()
