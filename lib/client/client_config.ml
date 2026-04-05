open Yojson.Safe.Util

module Assistant = struct
  type t = {
    route_model : string;
    system_prompt : string;
    max_tokens : int option;
  }
end

module Local_ops = struct
  type t = {
    workspace_root : string;
    max_read_bytes : int;
    max_exec_output_bytes : int;
    command_timeout_ms : int;
  }
end

module Human_terminal = struct
  type t = {
    show_routes_on_start : bool;
    conversation_keep_turns : int;
  }
end

module Machine_terminal = struct
  type t = { worker_jobs : int }
end

module Transport = struct
  module Ssh = struct
    type t = {
      human_remote_command : string;
      machine_remote_command : string;
      install_emit_command : string;
    }
  end

  module Http_workflow = struct
    type t = {
      base_url : string;
      server_command : string;
    }
  end

  module Http_distribution = struct
    type t = {
      base_url : string;
      server_command : string;
      install_url : string;
      archive_url : string;
    }
  end

  module Http = struct
    type t = {
      workflow : Http_workflow.t;
      distribution : Http_distribution.t;
    }
  end

  type t = {
    ssh : Ssh.t;
    http : Http.t;
  }
end

type t = {
  graph_runtime_path : string;
  assistant : Assistant.t;
  local_ops : Local_ops.t;
  human_terminal : Human_terminal.t;
  machine_terminal : Machine_terminal.t;
  transport : Transport.t;
}

let default_path = "config/client.json"

module Defaults = struct
  let default_client_config_path = "config/client.json"
  let default_http_workflow_base_url = "http://127.0.0.1:8087"
  let default_http_distribution_base_url = "http://127.0.0.1:8788"

  let ssh_human_remote_command ~client_config_path =
    Fmt.str
      "scripts/remote_human_terminal.sh --client-config %s"
      client_config_path

  let ssh_machine_remote_command ~client_config_path ~worker_jobs =
    Fmt.str
      "scripts/remote_machine_terminal.sh --client-config %s --jobs %d"
      client_config_path
      worker_jobs

  let ssh_install_emit_command =
    "scripts/remote_install.sh --emit-installer --origin user@host"

  let http_workflow_server_command ~client_config_path =
    Fmt.str
      "scripts/http_machine_server.sh --client-config %s --port 8087"
      client_config_path

  let http_distribution_server_command ~base_url =
    Fmt.str
      "scripts/http_dist_server.sh --public-base-url %s"
      base_url

  let http_distribution_install_url ~base_url = base_url ^ "/install.sh"
  let http_distribution_archive_url ~base_url = base_url ^ "/ocaml-agent-graph.tar.gz"
end

let parse_assistant ~base_dir json =
  let prompt_path =
    json
    |> member "system_prompt_file"
    |> to_string
    |> Config_support.resolve_relative_path ~base_dir
  in
  match Config_support.load_text_file prompt_path with
  | Error _ as error -> error
  | Ok system_prompt ->
      Ok
        {
          Assistant.route_model = json |> member "route_model" |> to_string;
          system_prompt;
          max_tokens = Config_support.member_int_option "max_tokens" json;
        }

let parse_local_ops ~base_dir json =
  {
    Local_ops.workspace_root =
      json
      |> member "workspace_root"
      |> to_string
      |> Config_support.resolve_relative_path ~base_dir;
    max_read_bytes =
      (match json |> member "max_read_bytes" with
       | `Null -> 32_000
       | value -> to_int value);
    max_exec_output_bytes =
      (match json |> member "max_exec_output_bytes" with
       | `Null -> 12_000
       | value -> to_int value);
    command_timeout_ms =
      (match json |> member "command_timeout_ms" with
       | `Null -> 10_000
       | value -> to_int value);
  }

let parse_human_terminal json =
  {
    Human_terminal.show_routes_on_start =
      (match json |> member "show_routes_on_start" with
       | `Null -> true
       | `Bool value -> value
       | _ -> true);
    conversation_keep_turns =
      (match json |> member "conversation_keep_turns" with
       | `Null -> 8
       | value -> to_int value);
  }

let parse_machine_terminal json =
  {
    Machine_terminal.worker_jobs =
      (match json |> member "worker_jobs" with
       | `Null -> 4
       | value -> to_int value);
  }

let member_or_null name = function
  | `Assoc fields ->
      (match List.assoc_opt name fields with
       | Some value -> value
       | None -> `Null)
  | _ -> `Null

let string_member_with_default name ~default json =
  match member_or_null name json with
  | `String value when String.trim value <> "" -> String.trim value
  | _ -> default

let parse_transport ~worker_jobs json =
  let transport_json = member_or_null "transport" json in
  let legacy_ssh_json = member_or_null "ssh" json in
  let ssh_json =
    match member_or_null "ssh" transport_json with
    | `Null -> legacy_ssh_json
    | value -> value
  in
  let http_json = member_or_null "http" transport_json in
  let workflow_json = member_or_null "workflow" http_json in
  let distribution_json = member_or_null "distribution" http_json in
  let default_client_config_path = Defaults.default_client_config_path in
  let default_distribution_base_url = Defaults.default_http_distribution_base_url in
  {
    Transport.ssh =
      {
        Transport.Ssh.human_remote_command =
          string_member_with_default
            "human_remote_command"
            ~default:(Defaults.ssh_human_remote_command ~client_config_path:default_client_config_path)
            ssh_json;
        machine_remote_command =
          string_member_with_default
            "machine_remote_command"
            ~default:
              (Defaults.ssh_machine_remote_command
                 ~client_config_path:default_client_config_path
                 ~worker_jobs)
            ssh_json;
        install_emit_command =
          string_member_with_default
            "install_emit_command"
            ~default:Defaults.ssh_install_emit_command
            ssh_json;
      };
    http =
      {
        Transport.Http.workflow =
          {
            Transport.Http_workflow.base_url =
              string_member_with_default
                "base_url"
                ~default:Defaults.default_http_workflow_base_url
                workflow_json;
            server_command =
              string_member_with_default
                "server_command"
                ~default:
                  (Defaults.http_workflow_server_command
                     ~client_config_path:default_client_config_path)
                workflow_json;
          };
        distribution =
          {
            Transport.Http_distribution.base_url =
              string_member_with_default
                "base_url"
                ~default:default_distribution_base_url
                distribution_json;
            server_command =
              string_member_with_default
                "server_command"
                ~default:
                  (Defaults.http_distribution_server_command
                     ~base_url:default_distribution_base_url)
                distribution_json;
            install_url =
              string_member_with_default
                "install_url"
                ~default:
                  (Defaults.http_distribution_install_url
                     ~base_url:default_distribution_base_url)
                distribution_json;
            archive_url =
              string_member_with_default
                "archive_url"
                ~default:
                  (Defaults.http_distribution_archive_url
                     ~base_url:default_distribution_base_url)
                distribution_json;
          };
      };
  }

let load path =
  try
    let json = Yojson.Safe.from_file path in
    let base_dir = Filename.dirname path in
    match parse_assistant ~base_dir (json |> member "assistant") with
    | Error _ as error -> error
    | Ok assistant ->
        let machine_terminal =
          json
          |> member "machine_terminal"
          |> parse_machine_terminal
        in
        Ok
          {
            graph_runtime_path =
              json
              |> member "graph_runtime_path"
              |> to_string
              |> Config_support.resolve_relative_path ~base_dir;
            assistant;
            local_ops = json |> member "local_ops" |> parse_local_ops ~base_dir;
            human_terminal =
              json
              |> member "human_terminal"
              |> parse_human_terminal;
            machine_terminal;
            transport = parse_transport ~worker_jobs:machine_terminal.worker_jobs json;
          }
  with
  | Sys_error message -> Error (Fmt.str "Cannot read %s: %s" path message)
  | Yojson.Json_error message ->
      Error (Fmt.str "Invalid JSON in %s: %s" path message)
  | Yojson.Safe.Util.Type_error (message, _) ->
      Error (Fmt.str "Invalid client configuration shape in %s: %s" path message)
