[@@@ocaml.warning "-4-26-27-32-41-42"]

open Catala_runtime

let double : integer -> integer = fun x -> Z.add x x

let () =
  Catala_runtime.register_module "Double_external"
    ["double", Obj.repr double]
    "*external*"
