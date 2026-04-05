let print_lines lines = List.iter print_endline lines

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o755)

let read_line_prompt prompt =
  print_string prompt;
  flush stdout;
  try Some (read_line ()) with
  | End_of_file -> None

let prompt_with_default ~default label =
  let suffix =
    if String.trim default = "" then "" else Fmt.str " [%s]" default
  in
  match read_line_prompt (label ^ suffix ^ ": ") with
  | Some value when String.trim value <> "" -> String.trim value
  | _ -> default

let prompt_yes_no ~default label =
  let default_label = if default then "Y/n" else "y/N" in
  match read_line_prompt (Fmt.str "%s [%s]: " label default_label) with
  | Some value ->
      let normalized = String.trim value |> String.lowercase_ascii in
      if normalized = "" then default
      else normalized = "y" || normalized = "yes"
  | None -> default

let write_json_file path json =
  ensure_dir (Filename.dirname path);
  Yojson.Safe.to_file path json

let default_http_workflow_port = 8087
let default_http_distribution_port = 8788

let config_json
    ~graph_runtime_path
    ~assistant_route_model
    ~prompt_file
    ~workspace_root
    ~worker_jobs
    ~client_config_path
  =
  `Assoc
    [
      "graph_runtime_path", `String graph_runtime_path;
      ( "assistant",
        `Assoc
          [
            "route_model", `String assistant_route_model;
            "system_prompt_file", `String prompt_file;
            "max_tokens", `Int 700;
          ] );
      ( "local_ops",
        `Assoc
          [
            "workspace_root", `String workspace_root;
            "max_read_bytes", `Int 32_000;
            "max_exec_output_bytes", `Int 12_000;
            "command_timeout_ms", `Int 10_000;
          ] );
      ( "human_terminal",
        `Assoc
          [
            "show_routes_on_start", `Bool true;
            "conversation_keep_turns", `Int 8;
          ] );
      "machine_terminal", `Assoc [ "worker_jobs", `Int worker_jobs ];
      ( "transport",
        `Assoc
          [
            ( "ssh",
              `Assoc
                [
                  ( "human_remote_command",
                    `String
                      (Client_config.Defaults.ssh_human_remote_command
                         ~client_config_path) );
                  ( "machine_remote_command",
                    `String
                      (Client_config.Defaults.ssh_machine_remote_command
                         ~client_config_path
                         ~worker_jobs) );
                  ( "install_emit_command",
                    `String Client_config.Defaults.ssh_install_emit_command );
                ] );
            ( "http",
              `Assoc
                [
                  ( "workflow",
                    `Assoc
                      [
                        ( "base_url",
                          `String Client_config.Defaults.default_http_workflow_base_url );
                        ( "server_command",
                          `String
                            (Fmt.str
                               "scripts/http_machine_server.sh --client-config %s --port %d"
                               client_config_path
                               default_http_workflow_port) );
                      ] );
                  ( "distribution",
                    `Assoc
                      [
                        ( "base_url",
                          `String
                            Client_config.Defaults.default_http_distribution_base_url );
                        ( "server_command",
                          `String
                            (Fmt.str
                               "scripts/http_dist_server.sh --public-base-url http://127.0.0.1:%d"
                               default_http_distribution_port) );
                        ( "install_url",
                          `String
                            (Client_config.Defaults.http_distribution_install_url
                               ~base_url:
                                 Client_config.Defaults.default_http_distribution_base_url) );
                        ( "archive_url",
                          `String
                            (Client_config.Defaults.http_distribution_archive_url
                               ~base_url:
                                 Client_config.Defaults.default_http_distribution_base_url) );
                      ] );
                ] );
          ] );
    ]

let choose_route_model (runtime : Client_runtime.t) =
  let available = Llm_aegis_client.route_models runtime.Client_runtime.llm_client in
  match available with
  | [] -> runtime.client_config.assistant.route_model
  | first :: _ ->
      print_endline "";
      print_endline "Available AegisLM routes:";
      print_lines (List.map (fun value -> "  - " ^ value) available);
      prompt_with_default ~default:first "Assistant route_model"

let build_config ~client_config_path () =
  let default_runtime_path = "runtime.json" in
  let runtime_path =
    prompt_with_default
      ~default:default_runtime_path
      "Graph runtime config path relative to the client config"
  in
  let workspace_root =
    prompt_with_default
      ~default:".."
      "Workspace root relative to the client config"
  in
  let prompt_file =
    prompt_with_default
      ~default:"prompts/graph_terminal_assistant.md"
      "Assistant prompt file relative to the client config"
  in
  let worker_jobs =
    prompt_with_default ~default:"4" "Machine worker parallel jobs"
    |> int_of_string_opt
    |> Option.value ~default:4
  in
  let base_dir = Filename.dirname client_config_path in
  let graph_runtime_path =
    Config_support.resolve_relative_path ~base_dir runtime_path
  in
  let assistant_route_model =
    match Runtime_config.load graph_runtime_path with
    | Error _ -> prompt_with_default ~default:"claude-sonnet" "Assistant route_model"
    | Ok runtime_config ->
        (match Llm_aegis_client.create runtime_config.llm with
         | Error _ ->
             prompt_with_default ~default:"claude-sonnet" "Assistant route_model"
         | Ok llm_client ->
             let assistant : Client_config.Assistant.t =
               {
                 route_model = "claude-sonnet";
                 system_prompt = "";
                 max_tokens = Some 700;
               }
             in
             let local_ops : Client_config.Local_ops.t =
               {
                 workspace_root;
                 max_read_bytes = 32_000;
                 max_exec_output_bytes = 12_000;
                 command_timeout_ms = 10_000;
               }
             in
             let human_terminal : Client_config.Human_terminal.t =
               {
                 show_routes_on_start = true;
                 conversation_keep_turns = 8;
               }
             in
             let machine_terminal : Client_config.Machine_terminal.t =
               { worker_jobs }
             in
             let transport : Client_config.Transport.t =
               {
                 ssh =
                   {
                     Client_config.Transport.Ssh.human_remote_command = "";
                     machine_remote_command = "";
                     install_emit_command = "";
                   };
                 http =
                   {
                     Client_config.Transport.Http.workflow =
                       {
                         Client_config.Transport.Http_workflow.base_url = "";
                         server_command = "";
                       };
                     distribution =
                       {
                         Client_config.Transport.Http_distribution.base_url = "";
                         server_command = "";
                         install_url = "";
                         archive_url = "";
                       };
                   };
               }
             in
             let provisional_config : Client_config.t =
               {
                 graph_runtime_path;
                 assistant;
                 local_ops;
                 human_terminal;
                 machine_terminal;
                 transport;
               }
             in
             let runtime =
               Client_runtime.of_parts
                 ~client_config_path
                 ~client_config:provisional_config
                 ~runtime_config_path:graph_runtime_path
                 ~runtime_config
                 ~llm_client
             in
             choose_route_model runtime)
  in
  let json =
    config_json
      ~graph_runtime_path:runtime_path
      ~assistant_route_model
      ~prompt_file
      ~workspace_root
      ~worker_jobs
      ~client_config_path
  in
  write_json_file client_config_path json;
  client_config_path

let run ~client_config_path () =
  print_endline "ocaml-agent-graph starter";
  print_lines
    [
      "This wizard prepares a human terminal and a machine worker config.";
      "It reuses the graph runtime and AegisLM gateway already configured by the repository.";
    ];
  let selected_path =
    if Sys.file_exists client_config_path then
      if prompt_yes_no ~default:true (Fmt.str "Reuse %s" client_config_path)
      then client_config_path
      else build_config ~client_config_path ()
    else build_config ~client_config_path ()
  in
  match Client_runtime.load selected_path with
  | Error message ->
      prerr_endline message;
      1
  | Ok runtime -> Client_terminal.run runtime
