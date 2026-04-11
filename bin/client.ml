open Cmdliner
open Agent_graph

module Client_config = Client.Config
module Client_runtime = Client.Runtime
module Client_machine = Client.Machine
module Client_terminal = Client.Terminal
module Client_starter = Client.Starter
module Client_http_server = Client.Http_server

let client_config_term =
  let doc = "Path to the terminal client JSON configuration file." in
  Arg.(
    value
    & opt string Client_config.default_path
    & info [ "client-config" ] ~docv:"FILE" ~doc)

let route_model_term =
  let doc = "Override the assistant route_model for this human terminal session." in
  Arg.(value & opt (some string) None & info [ "route-model" ] ~docv:"MODEL" ~doc)

let jobs_term =
  let doc = "Maximum concurrent jobs for the JSONL worker mode." in
  Arg.(value & opt int 4 & info [ "jobs" ] ~docv:"N" ~doc)

let port_term =
  let doc = "TCP port for the workflow HTTP server." in
  Arg.(value & opt int 8087 & info [ "port" ] ~docv:"PORT" ~doc)

let kind_term =
  let kinds =
    [
      "assistant", Client_machine.Assistant;
      "inspect_graph", Client_machine.Inspect_graph;
      "run_graph", Client_machine.Run_graph;
      "messenger_spokesperson", Client_machine.Messenger_spokesperson;
    ]
  in
  let doc = "Kind of machine request to read from stdin." in
  Arg.(
    value
    & opt (enum kinds) Client_machine.Assistant
    & info [ "kind" ] ~docv:"KIND" ~doc)

let load_runtime client_config_path =
  match Client_runtime.load client_config_path with
  | Error message -> `Error (false, message)
  | Ok runtime -> `Ok runtime

let exit_if_nonzero = function
  | 0 -> ()
  | code -> Stdlib.exit code

let run_ask client_config_path route_model =
  match load_runtime client_config_path with
  | `Error _ as error -> error
  | `Ok runtime ->
      let runtime =
        match route_model with
        | None -> runtime
        | Some route_model ->
            let client_config =
              {
                runtime.Client_runtime.client_config with
                assistant =
                  {
                    runtime.client_config.assistant with
                    route_model;
                  };
              }
            in
            Client_runtime.of_parts
              ~client_config_path:runtime.client_config_path
              ~client_config
              ~runtime_config_path:runtime.runtime_config_path
              ~runtime_config:runtime.runtime_config
              ~llm_client:runtime.llm_client
      in
      `Ok (exit_if_nonzero (Client_terminal.run runtime))

let read_stdin_json () =
  try Ok (Yojson.Safe.from_channel stdin) with
  | Yojson.Json_error message -> Error (Fmt.str "Invalid JSON on stdin: %s" message)

let run_call client_config_path kind =
  match load_runtime client_config_path with
  | `Error _ as error -> error
  | `Ok runtime ->
      (match read_stdin_json () with
       | Error message -> `Error (false, message)
       | Ok json ->
           (match Lwt_main.run (Client_machine.invoke_json runtime ~kind json) with
            | Error message -> `Error (false, message)
            | Ok response ->
               print_endline
                  (Client_machine.call_response_to_yojson response
                   |> Yojson.Safe.pretty_to_string);
                `Ok ()))

let run_worker client_config_path jobs =
  match load_runtime client_config_path with
  | `Error _ as error -> error
  | `Ok runtime ->
      Lwt_main.run (Client_machine.run_stdio runtime ~jobs ());
      `Ok ()

let run_starter client_config_path =
  `Ok (exit_if_nonzero (Client_starter.run ~client_config_path ()))

let run_serve_http client_config_path port =
  match load_runtime client_config_path with
  | `Error _ as error -> error
  | `Ok runtime -> `Ok (Client_http_server.run ~port runtime)

let ask_cmd =
  let doc = "Human-friendly terminal for configuring agent graphs." in
  Cmd.v
    (Cmd.info "ask" ~doc)
    Term.(ret (const run_ask $ client_config_term $ route_model_term))

let call_cmd =
  let doc =
    "One-shot machine client. Reads one JSON request on stdin and prints one JSON response."
  in
  Cmd.v
    (Cmd.info "call" ~doc)
    Term.(ret (const run_call $ client_config_term $ kind_term))

let worker_cmd =
  let doc =
    "JSONL worker mode for concurrent machine requests against one shared client runtime."
  in
  Cmd.v
    (Cmd.info "worker" ~doc)
    Term.(ret (const run_worker $ client_config_term $ jobs_term))

let starter_cmd =
  let doc =
    "Interactive starter wizard that writes a client config and launches the human terminal."
  in
  Cmd.v
    (Cmd.info "starter" ~doc)
    Term.(ret (const run_starter $ client_config_term))

let serve_http_cmd =
  let doc =
    "Workflow HTTP server for programmatic calls plus the OpenAI-compatible messenger spokesperson endpoint."
  in
  Cmd.v
    (Cmd.info "serve-http" ~doc)
    Term.(ret (const run_serve_http $ client_config_term $ port_term))

let command =
  let doc = "Human and machine terminal clients for ocaml-agent-graph." in
  Cmd.group
    (Cmd.info "ocaml-agent-graph-client" ~doc)
    [ ask_cmd; call_cmd; worker_cmd; starter_cmd; serve_http_cmd ]

let () = exit (Cmd.eval command)
