let all : Agent_intf.packed list =
  [
    (module Planner_agent : Agent_intf.S);
    (module Summarizer_agent : Agent_intf.S);
    (module Validator_agent : Agent_intf.S);
  ]

let make_registry () =
  let registry = Runtime_registry.create 8 in
  List.iter (Runtime_registry.register registry) all;
  registry

