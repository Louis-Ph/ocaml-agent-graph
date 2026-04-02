open Cmdliner

let config_path =
  let doc = "Path to the runtime JSON configuration." in
  Arg.(
    value
    & opt string "config/runtime.json"
    & info [ "config" ] ~docv:"FILE" ~doc)

let task_id =
  let doc = "Override the task identifier from the configuration file." in
  Arg.(value & opt (some string) None & info [ "task-id" ] ~docv:"TASK" ~doc)

let input =
  let doc = "Override the demo input from the configuration file." in
  Arg.(value & pos 0 (some string) None & info [] ~docv:"INPUT" ~doc)

let run config_path task_id input =
  match Agent_graph.Config.Runtime.load config_path with
  | Error message -> `Error (false, message)
  | Ok config ->
      let resolved_task_id =
        Option.value task_id ~default:config.demo.task_id
      in
      let resolved_input =
        Option.value input ~default:config.demo.input
      in
      let payload, context =
        Lwt_main.run
          (Agent_graph.run
             ~config
             ~task_id:resolved_task_id
             ~input:resolved_input
             ())
      in
      Fmt.pr "task_id: %s\n" context.task_id;
      Fmt.pr
        "completed_agents: %s\n\n"
        (Agent_graph.Core.Context.completed_agent_names context
        |> String.concat ", ");
      Fmt.pr "%s\n" (Agent_graph.Core.Payload.to_pretty_string payload);
      `Ok ()

let command =
  let doc = "Run the typed multi-agent orchestration demo." in
  let info = Cmd.info "ocaml-agent-graph-demo" ~doc in
  Cmd.v info Term.(ret (const run $ config_path $ task_id $ input))

let () = exit (Cmd.eval command)
