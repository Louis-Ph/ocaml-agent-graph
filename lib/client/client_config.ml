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

module Ssh = struct
  type t = {
    human_remote_command : string;
    machine_remote_command : string;
  }
end

type t = {
  graph_runtime_path : string;
  assistant : Assistant.t;
  local_ops : Local_ops.t;
  human_terminal : Human_terminal.t;
  machine_terminal : Machine_terminal.t;
  ssh : Ssh.t;
}

let default_path = "config/client.json"

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

let parse_ssh json =
  {
    Ssh.human_remote_command =
      (match json |> member "human_remote_command" with
       | `String value when String.trim value <> "" -> String.trim value
       | _ ->
           "scripts/remote_human_terminal.sh --client-config config/client.json");
    machine_remote_command =
      (match json |> member "machine_remote_command" with
       | `String value when String.trim value <> "" -> String.trim value
       | _ ->
           "scripts/remote_machine_terminal.sh --client-config config/client.json");
  }

let load path =
  try
    let json = Yojson.Safe.from_file path in
    let base_dir = Filename.dirname path in
    match parse_assistant ~base_dir (json |> member "assistant") with
    | Error _ as error -> error
    | Ok assistant ->
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
            machine_terminal =
              json
              |> member "machine_terminal"
              |> parse_machine_terminal;
            ssh = json |> member "ssh" |> parse_ssh;
          }
  with
  | Sys_error message -> Error (Fmt.str "Cannot read %s: %s" path message)
  | Yojson.Json_error message ->
      Error (Fmt.str "Invalid JSON in %s: %s" path message)
  | Yojson.Safe.Util.Type_error (message, _) ->
      Error (Fmt.str "Invalid client configuration shape in %s: %s" path message)

