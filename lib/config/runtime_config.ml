open Yojson.Safe.Util

module Engine = struct
  type t = {
    timeout_seconds : float;
    retry_attempts : int;
    retry_backoff_seconds : float;
    max_steps : int;
  }
end

module Routing = struct
  type t = {
    long_text_threshold : int;
    short_text_agent : Core_agent_name.t;
    planner_agent : Core_agent_name.t;
    parallel_agents : Core_agent_name.t list;
  }
end

module Demo = struct
  type t = {
    task_id : string;
    input : string;
  }
end

module Llm = struct
  module Agent_profile = struct
    type t = {
      route_model : string;
      system_prompt : string;
      max_tokens : int option;
      confidence : float;
    }
  end

  type t = {
    gateway_config_path : string;
    authorization_token_plaintext : string option;
    authorization_token_env : string option;
    planner : Agent_profile.t;
    summarizer : Agent_profile.t;
    validator : Agent_profile.t;
  }

  let profile_for_agent t = function
    | Core_agent_name.Planner -> t.planner
    | Summarizer -> t.summarizer
    | Validator -> t.validator

  let agent_bindings t =
    [
      Core_agent_name.Planner, t.planner;
      Summarizer, t.summarizer;
      Validator, t.validator;
    ]
end

module Memory = struct
  module Storage = struct
    type mode =
      | Bulkhead_gateway_sqlite
      | Explicit_sqlite

    type t = {
      mode : mode;
      sqlite_path : string option;
    }
  end

  module Reload = struct
    type t = {
      recent_turn_buffer : int;
    }
  end

  module Compression = struct
    type t = {
      reply_checkpoints : int list;
      continue_every_replies : int;
      summary_max_chars : int;
      summary_max_tokens : int option;
      summary_prompt : string;
    }
  end

  module Bulkhead_bridge = struct
    type t = {
      endpoint_url : string;
      session_key_prefix : string option;
      authorization_token_plaintext : string option;
      authorization_token_env : string option;
      timeout_seconds : float;
    }
  end

  type t = {
    enabled : bool;
    session_namespace : string;
    session_id_metadata_key : string option;
    storage : Storage.t;
    reload : Reload.t;
    compression : Compression.t;
    bulkhead_bridge : Bulkhead_bridge.t option;
  }

  let disabled =
    {
      enabled = false;
      session_namespace = "default";
      session_id_metadata_key = None;
      storage =
        { Storage.mode = Bulkhead_gateway_sqlite; sqlite_path = None };
      reload = { Reload.recent_turn_buffer = 4 };
      compression =
        {
          Compression.reply_checkpoints = [ 5; 7; 10; 15; 20 ];
          continue_every_replies = 5;
          summary_max_chars = 2400;
          summary_max_tokens = None;
          summary_prompt =
            "Compress this durable swarm memory into a short, factual note.";
        };
      bulkhead_bridge = None;
    }
end

type t = {
  engine : Engine.t;
  routing : Routing.t;
  demo : Demo.t;
  llm : Llm.t;
  memory : Memory.t;
}

let default_path = "config/runtime.json"

let agent_of_string value =
  match Core_agent_name.of_string value with
  | Ok agent -> agent
  | Error message -> invalid_arg message

let parse_engine json =
  {
    Engine.timeout_seconds = json |> member "timeout_seconds" |> to_float;
    retry_attempts = json |> member "retry_attempts" |> to_int;
    retry_backoff_seconds =
      json |> member "retry_backoff_seconds" |> to_float;
    max_steps = json |> member "max_steps" |> to_int;
  }

let parse_routing json =
  {
    Routing.long_text_threshold =
      json |> member "long_text_threshold" |> to_int;
    short_text_agent =
      json |> member "short_text_agent" |> to_string |> agent_of_string;
    planner_agent =
      json |> member "planner_agent" |> to_string |> agent_of_string;
    parallel_agents =
      json
      |> member "parallel_agents"
      |> to_list
      |> List.map to_string
      |> List.map agent_of_string;
  }

let parse_demo json =
  {
    Demo.task_id = json |> member "task_id" |> to_string;
    input = json |> member "input" |> to_string;
  }

let parse_agent_profile json =
  let route_model =
    match Config_support.member_string_option "route_model" json with
    | Some value -> value
    | None -> json |> member "model" |> to_string
  in
  {
    Llm.Agent_profile.route_model;
    system_prompt = json |> member "system_prompt" |> to_string;
    max_tokens = Config_support.member_int_option "max_tokens" json;
    confidence = json |> member "confidence" |> to_float;
  }

let parse_llm ~base_dir json =
  {
    Llm.gateway_config_path =
      json
      |> member "gateway_config_path"
      |> to_string
      |> Config_support.resolve_relative_path ~base_dir;
    authorization_token_plaintext =
      Config_support.member_string_option
        "authorization_token_plaintext"
        json;
    authorization_token_env =
      Config_support.member_string_option "authorization_token_env" json;
    planner = json |> member "planner" |> parse_agent_profile;
    summarizer = json |> member "summarizer" |> parse_agent_profile;
    validator = json |> member "validator" |> parse_agent_profile;
  }

let bool_member_with_default name json ~default =
  match json |> member name with
  | `Bool value -> value
  | _ -> default

let parse_storage_mode value =
  match String.lowercase_ascii (String.trim value) with
  | "bulkhead_gateway_sqlite" -> Ok Memory.Storage.Bulkhead_gateway_sqlite
  | "explicit_sqlite" -> Ok Memory.Storage.Explicit_sqlite
  | invalid ->
      Error
        (Fmt.str
           "Invalid memory storage mode: %s. Expected bulkhead_gateway_sqlite or explicit_sqlite."
           invalid)

let list_of_ints_member name json =
  match json |> member name with
  | `List values ->
      values
      |> List.filter_map (function
             | `Int value -> Some value
             | `Intlit value -> Some (int_of_string value)
             | _ -> None)
  | _ -> []

let non_empty_string_member name json =
  json
  |> member name
  |> to_string_option
  |> Option.map String.trim
  |> function
  | Some value when value <> "" -> Some value
  | _ -> None

let parse_bulkhead_bridge json =
  match non_empty_string_member "endpoint_url" json with
  | None ->
      Error
        "Invalid memory bulkhead_bridge configuration: endpoint_url is required."
  | Some endpoint_url ->
      Ok
        {
          Memory.Bulkhead_bridge.endpoint_url;
          session_key_prefix = non_empty_string_member "session_key_prefix" json;
          authorization_token_plaintext =
            non_empty_string_member "authorization_token_plaintext" json;
          authorization_token_env =
            non_empty_string_member "authorization_token_env" json;
          timeout_seconds =
            (json
            |> member "timeout_seconds"
            |> to_float_option
            |> Option.value ~default:5.0
            |> max 0.1);
        }

let parse_memory ~base_dir json =
  let storage_json = json |> member "storage" in
  let reload_json = json |> member "reload" in
  let compression_json = json |> member "compression" in
  let bulkhead_bridge =
    match json |> member "bulkhead_bridge" with
    | `Null -> Ok None
    | (`Assoc _ as bridge_json) ->
        parse_bulkhead_bridge bridge_json |> Result.map Option.some
    | _ ->
        Error
          "Invalid memory bulkhead_bridge configuration: expected an object."
  in
  let storage_mode =
    storage_json
    |> member "mode"
    |> to_string_option
    |> Option.value ~default:"bulkhead_gateway_sqlite"
    |> parse_storage_mode
  in
  match bulkhead_bridge, storage_mode with
  | (Error _ as error), _ -> error
  | _, (Error _ as error) -> error
  | Ok bulkhead_bridge, Ok storage_mode ->
      Ok
        {
          Memory.enabled =
            bool_member_with_default "enabled" json ~default:true;
          session_namespace =
            json
            |> member "session_namespace"
            |> to_string_option
            |> Option.value ~default:"default";
          session_id_metadata_key =
            Config_support.member_string_option
              "session_id_metadata_key"
              json;
          storage =
            {
              Memory.Storage.mode = storage_mode;
              sqlite_path =
                storage_json
                |> member "sqlite_path"
                |> to_string_option
                |> Option.map
                     (Config_support.resolve_relative_path ~base_dir);
            };
          reload =
            {
              Memory.Reload.recent_turn_buffer =
                max
                  0
                  (reload_json
                  |> member "recent_turn_buffer"
                  |> to_int_option
                  |> Option.value ~default:4);
            };
          compression =
            {
              Memory.Compression.reply_checkpoints =
                (match list_of_ints_member "reply_checkpoints" compression_json with
                | [] -> [ 5; 7; 10; 15; 20 ]
                | values -> values |> List.sort_uniq Int.compare);
              continue_every_replies =
                max
                  1
                  (compression_json
                  |> member "continue_every_replies"
                  |> to_int_option
                  |> Option.value ~default:5);
              summary_max_chars =
                max
                  120
                  (compression_json
                  |> member "summary_max_chars"
                  |> to_int_option
                  |> Option.value ~default:2400);
              summary_max_tokens =
                compression_json
                |> member "summary_max_tokens"
                |> to_int_option;
              summary_prompt =
                compression_json
                |> member "summary_prompt"
                |> to_string_option
                |> Option.value
                     ~default:
                       "Compress this durable swarm memory into a short, factual note.";
            };
          bulkhead_bridge;
        }

let load path =
  try
    let json = Yojson.Safe.from_file path in
    let base_dir = Filename.dirname path in
    let memory =
      match Config_support.member_string_option "memory_policy_path" json with
      | None -> Ok Memory.disabled
      | Some memory_policy_path ->
          let resolved_path =
            Config_support.resolve_relative_path
              ~base_dir
              memory_policy_path
          in
          let memory_json = Yojson.Safe.from_file resolved_path in
          parse_memory ~base_dir:(Filename.dirname resolved_path) memory_json
    in
    (match memory with
    | Error _ as error -> error
    | Ok memory ->
        Ok
          {
            engine = json |> member "engine" |> parse_engine;
            routing = json |> member "routing" |> parse_routing;
            demo = json |> member "demo" |> parse_demo;
            llm = json |> member "llm" |> parse_llm ~base_dir;
            memory;
          })
  with
  | Sys_error message -> Error (Fmt.str "Cannot read %s: %s" path message)
  | Yojson.Json_error message ->
      Error (Fmt.str "Invalid JSON in %s: %s" path message)
  | Yojson.Safe.Util.Type_error (message, _) ->
      Error (Fmt.str "Invalid configuration shape in %s: %s" path message)
  | Invalid_argument message ->
      Error (Fmt.str "Invalid configuration value in %s: %s" path message)
