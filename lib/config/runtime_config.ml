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

module Discussion = struct
  module Versioned_text = struct
    type t = {
      version : string;
      text : string;
      source_path : string option;
    }
  end

  module Participant = struct
    let default_system_prompt =
      "You are a participant inside a structured multi-agent discussion. Follow the configured persona and rules, stay in role, contribute one compact step, and avoid repeating the transcript."

    type t = {
      name : string;
      profile : Llm.Agent_profile.t;
      persona : Versioned_text.t option;
      rules : Versioned_text.t option;
    }
  end

  type t = {
    enabled : bool;
    rounds : int;
    max_nesting_depth : int;
    final_agent : Core_agent_name.t;
    participants : Participant.t list;
  }

  let disabled =
    {
      enabled = false;
      rounds = 2;
      max_nesting_depth = 0;
      final_agent = Core_agent_name.Summarizer;
      participants = [];
    }

  let route_models t =
    t.participants
    |> List.map (fun participant -> participant.Participant.profile.route_model)
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
    module Trigger = struct
      type mode =
        | Explicit_checkpoints
        | Fibonacci

      type t = {
        mode : mode;
        reply_checkpoints : int list;
        continue_every_replies : int;
        fibonacci_first_reply : int;
        fibonacci_second_reply : int;
      }
    end

    module Budget = struct
      type mode =
        | Fixed_budget
        | Fibonacci_decay

      type t = {
        mode : mode;
        base_summary_max_chars : int;
        min_summary_max_chars : int;
        base_summary_max_tokens : int option;
        min_summary_max_tokens : int option;
      }
    end

    module Value_hierarchy = struct
      type t = {
        keep_verbatim : string list;
        keep_strongly : string list;
        compress_first : string list;
        drop_first : string list;
      }
    end

    type t = {
      policy_name : string;
      trigger : Trigger.t;
      budget : Budget.t;
      value_hierarchy : Value_hierarchy.t;
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
          Compression.policy_name = "fibonacci_durable_memory_v1";
          trigger =
            {
              Compression.Trigger.mode = Compression.Trigger.Fibonacci;
              reply_checkpoints = [ 5; 7; 10; 15; 20 ];
              continue_every_replies = 5;
              fibonacci_first_reply = 5;
              fibonacci_second_reply = 8;
            };
          budget =
            {
              Compression.Budget.mode = Compression.Budget.Fibonacci_decay;
              base_summary_max_chars = 2400;
              min_summary_max_chars = 480;
              base_summary_max_tokens = Some 220;
              min_summary_max_tokens = Some 96;
            };
          value_hierarchy =
            {
              Compression.Value_hierarchy.keep_verbatim =
                [
                  "stable identifiers, names, and session anchors";
                  "explicit user preferences that must not drift";
                  "irreversible decisions that were already made";
                ];
              keep_strongly =
                [
                  "goals and success criteria";
                  "hard constraints, blockers, budgets, and deadlines";
                  "open questions, risks, and unresolved dependencies";
                ];
              compress_first =
                [
                  "supporting reasoning details once the conclusion is stable";
                  "intermediate plans that were superseded by a better one";
                  "context that is useful but not mission-critical";
                ];
              drop_first =
                [
                  "stylistic wording and pleasantries";
                  "repetition and low-signal filler";
                  "obsolete alternatives that are no longer actionable";
                ];
            };
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
  discussion : Discussion.t;
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

let parse_discussion_profile json =
  let route_model =
    match Config_support.member_string_option "route_model" json with
    | Some value -> value
    | None -> json |> member "model" |> to_string
  in
  let system_prompt =
    match json |> member "system_prompt" with
    | `String value ->
        let trimmed = String.trim value in
        if trimmed = ""
        then Discussion.Participant.default_system_prompt
        else trimmed
    | _ -> Discussion.Participant.default_system_prompt
  in
  {
    Llm.Agent_profile.route_model;
    system_prompt;
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

let parse_compression_trigger_mode value =
  match String.lowercase_ascii (String.trim value) with
  | "explicit" | "explicit_checkpoints" ->
      Ok Memory.Compression.Trigger.Explicit_checkpoints
  | "fibonacci" | "fibonacci_checkpoints" ->
      Ok Memory.Compression.Trigger.Fibonacci
  | invalid ->
      Error
        (Fmt.str
           "Invalid memory compression trigger mode: %s. Expected explicit_checkpoints or fibonacci."
           invalid)

let parse_compression_budget_mode value =
  match String.lowercase_ascii (String.trim value) with
  | "fixed" | "fixed_budget" -> Ok Memory.Compression.Budget.Fixed_budget
  | "fibonacci" | "fibonacci_decay" ->
      Ok Memory.Compression.Budget.Fibonacci_decay
  | invalid ->
      Error
        (Fmt.str
           "Invalid memory compression budget mode: %s. Expected fixed_budget or fibonacci_decay."
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

let list_of_strings_member name json =
  match json |> member name with
  | `List values ->
      values
      |> List.filter_map (function
             | `String value when String.trim value <> "" -> Some (String.trim value)
             | _ -> None)
  | _ -> []

let first_some a b =
  match a with
  | Some _ -> a
  | None -> b

let non_empty_string_member name json =
  json
  |> member name
  |> to_string_option
  |> Option.map String.trim
  |> function
  | Some value when value <> "" -> Some value
  | _ -> None

let versioned_text_member names json =
  let rec loop = function
    | [] -> `Null
    | name :: rest ->
        (match json |> member name with
         | `Null -> loop rest
         | value -> value)
  in
  loop names

let parse_versioned_text ~base_dir ~field_names json =
  match versioned_text_member field_names json with
  | `Null -> Ok None
  | (`Assoc _ as value_json) ->
      let field_label = String.concat "/" field_names in
      (match non_empty_string_member "version" value_json with
       | None ->
           Error
             (Fmt.str
                "Invalid discussion %s configuration: version is required."
                field_label)
       | Some version ->
           let text = non_empty_string_member "text" value_json in
           let file_path =
             non_empty_string_member "file_path" value_json
           in
           (match text, file_path with
            | Some _, Some _ ->
                Error
                  (Fmt.str
                     "Invalid discussion %s configuration: use either text or file_path, not both."
                     field_label)
            | None, None ->
                Error
                  (Fmt.str
                     "Invalid discussion %s configuration: text or file_path is required."
                     field_label)
            | Some text, None ->
                Ok
                  (Some
                     {
                       Discussion.Versioned_text.version;
                       text;
                       source_path = None;
                     })
            | None, Some file_path ->
                let resolved_path =
                  Config_support.resolve_relative_path ~base_dir file_path
                in
                (match Config_support.load_text_file resolved_path with
                 | Ok text ->
                     let text = String.trim text in
                     if text = ""
                     then
                       Error
                         (Fmt.str
                            "Invalid discussion %s configuration: %s is empty."
                            field_label
                            resolved_path)
                     else
                       Ok
                         (Some
                            {
                              Discussion.Versioned_text.version;
                              text;
                              source_path = Some resolved_path;
                            })
                 | Error message ->
                     Error
                       (Fmt.str
                          "Invalid discussion %s configuration: %s"
                          field_label
                          message))))
  | _ ->
      Error
        (Fmt.str
           "Invalid discussion %s configuration: expected an object."
           (String.concat "/" field_names))

let parse_discussion_participant ~base_dir json =
  match non_empty_string_member "name" json with
  | None ->
      Error
        "Invalid discussion participant configuration: name is required."
  | Some name ->
      let persona =
        parse_versioned_text
          ~base_dir
          ~field_names:[ "persona"; "personna" ]
          json
      in
      let rules =
        parse_versioned_text
          ~base_dir
          ~field_names:[ "rules" ]
          json
      in
      (match persona, rules with
       | (Error _ as error), _ -> error
       | _, (Error _ as error) -> error
       | Ok persona, Ok rules ->
           Ok
             {
               Discussion.Participant.name;
               profile = parse_discussion_profile json;
               persona;
               rules;
             })

let discussion_supports_agent = function
  | Core_agent_name.Summarizer | Validator -> true
  | Planner -> false

let parse_discussion ~base_dir json =
  let enabled = bool_member_with_default "enabled" json ~default:false in
  let rounds =
    json
    |> member "rounds"
    |> to_int_option
    |> Option.value ~default:Discussion.disabled.rounds
  in
  let max_nesting_depth =
    json
    |> member "max_nesting_depth"
    |> to_int_option
    |> Option.value ~default:Discussion.disabled.max_nesting_depth
  in
  let final_agent =
    json
    |> member "final_agent"
    |> to_string_option
    |> Option.value
         ~default:(Core_agent_name.to_string Discussion.disabled.final_agent)
    |> agent_of_string
  in
  let participants =
    match json |> member "participants" with
    | `Null -> Ok []
    | `List values ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | (`Assoc _ as participant_json) :: rest ->
              (match parse_discussion_participant ~base_dir participant_json with
               | Ok participant -> loop (participant :: acc) rest
               | Error _ as error -> error)
          | _ :: _ ->
              Error
                "Invalid discussion configuration: participants must be objects."
        in
        loop [] values
    | _ ->
        Error
          "Invalid discussion configuration: participants must be a list."
  in
  if rounds <= 0
  then Error "Invalid discussion configuration: rounds must be >= 1."
  else if enabled && not (discussion_supports_agent final_agent)
  then
    Error
      "Invalid discussion configuration: final_agent must be summarizer or validator."
  else
    match participants with
    | Error _ as error -> error
    | Ok participants when enabled && participants = [] ->
        Error
          "Invalid discussion configuration: enable discussion only when at least one participant is configured."
    | Ok participants ->
        Ok
          {
            Discussion.enabled;
            rounds;
            max_nesting_depth;
            final_agent;
            participants;
          }

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
  let trigger_json = compression_json |> member "trigger" in
  let budget_json = compression_json |> member "budget" in
  let value_hierarchy_json = compression_json |> member "value_hierarchy" in
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
  let has_legacy_trigger_fields =
    trigger_json = `Null
    && (compression_json |> member "reply_checkpoints" <> `Null
        || compression_json |> member "continue_every_replies" <> `Null)
  in
  let has_legacy_budget_fields =
    budget_json = `Null
    && (compression_json |> member "summary_max_chars" <> `Null
        || compression_json |> member "summary_max_tokens" <> `Null)
  in
  let legacy_reply_checkpoints =
    match list_of_ints_member "reply_checkpoints" compression_json with
    | [] -> [ 5; 7; 10; 15; 20 ]
    | values -> values |> List.sort_uniq Int.compare
  in
  let trigger_mode =
    if trigger_json = `Null && not has_legacy_trigger_fields
    then Ok Memory.Compression.Trigger.Fibonacci
    else
      match trigger_json |> member "mode" |> to_string_option with
      | Some value -> parse_compression_trigger_mode value
      | None when has_legacy_trigger_fields ->
          Ok Memory.Compression.Trigger.Explicit_checkpoints
      | None -> Ok Memory.Compression.Trigger.Fibonacci
  in
  let budget_mode =
    if budget_json = `Null && not has_legacy_budget_fields
    then Ok Memory.Compression.Budget.Fibonacci_decay
    else
      match budget_json |> member "mode" |> to_string_option with
      | Some value -> parse_compression_budget_mode value
      | None when has_legacy_budget_fields ->
          Ok Memory.Compression.Budget.Fixed_budget
      | None -> Ok Memory.Compression.Budget.Fibonacci_decay
  in
  match bulkhead_bridge, storage_mode, trigger_mode, budget_mode with
  | (Error _ as error), _, _, _ -> error
  | _, (Error _ as error), _, _ -> error
  | _, _, (Error _ as error), _ -> error
  | _, _, _, (Error _ as error) -> error
  | Ok bulkhead_bridge, Ok storage_mode, Ok trigger_mode, Ok budget_mode ->
      let trigger_reply_checkpoints =
        match list_of_ints_member "reply_checkpoints" trigger_json with
        | [] -> legacy_reply_checkpoints
        | values -> values |> List.sort_uniq Int.compare
      in
      let continue_every_replies =
        max
          1
          (first_some
             (trigger_json |> member "continue_every_replies" |> to_int_option)
             (compression_json |> member "continue_every_replies" |> to_int_option)
          |> Option.value ~default:5)
      in
      let fibonacci_first_reply =
        max
          1
          (trigger_json
          |> member "fibonacci_first_reply"
          |> to_int_option
          |> Option.value ~default:5)
      in
      let fibonacci_second_reply =
        max
          (fibonacci_first_reply + 1)
          (trigger_json
          |> member "fibonacci_second_reply"
          |> to_int_option
          |> Option.value ~default:8)
      in
      let base_summary_max_chars =
        max
          120
          (first_some
             (budget_json |> member "base_summary_max_chars" |> to_int_option)
             (compression_json |> member "summary_max_chars" |> to_int_option)
          |> Option.value ~default:2400)
      in
      let base_summary_max_tokens =
        first_some
          (budget_json |> member "base_summary_max_tokens" |> to_int_option)
          (compression_json |> member "summary_max_tokens" |> to_int_option)
      in
      let min_summary_max_chars =
        max
          120
          (budget_json
          |> member "min_summary_max_chars"
          |> to_int_option
          |> Option.value
               ~default:
                 (match budget_mode with
                  | Memory.Compression.Budget.Fixed_budget ->
                      base_summary_max_chars
                  | Memory.Compression.Budget.Fibonacci_decay -> 480))
      in
      let min_summary_max_tokens =
        budget_json
        |> member "min_summary_max_tokens"
        |> to_int_option
        |> first_some
             (match budget_mode, base_summary_max_tokens with
              | Memory.Compression.Budget.Fixed_budget, Some value -> Some value
              | _, _ -> Some 96)
      in
      let value_hierarchy =
        {
          Memory.Compression.Value_hierarchy.keep_verbatim =
            (match list_of_strings_member "keep_verbatim" value_hierarchy_json with
             | [] ->
                 [
                   "stable identifiers, names, and session anchors";
                   "explicit user preferences that must not drift";
                   "irreversible decisions that were already made";
                 ]
             | values -> values);
          keep_strongly =
            (match list_of_strings_member "keep_strongly" value_hierarchy_json with
             | [] ->
                 [
                   "goals and success criteria";
                   "hard constraints, blockers, budgets, and deadlines";
                   "open questions, risks, and unresolved dependencies";
                 ]
             | values -> values);
          compress_first =
            (match list_of_strings_member "compress_first" value_hierarchy_json with
             | [] ->
                 [
                   "supporting reasoning details once the conclusion is stable";
                   "intermediate plans that were superseded by a better one";
                   "context that is useful but not mission-critical";
                 ]
             | values -> values);
          drop_first =
            (match list_of_strings_member "drop_first" value_hierarchy_json with
             | [] ->
                 [
                   "stylistic wording and pleasantries";
                   "repetition and low-signal filler";
                   "obsolete alternatives that are no longer actionable";
                 ]
             | values -> values);
        }
      in
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
              Memory.Compression.policy_name =
                compression_json
                |> member "policy_name"
                |> to_string_option
                |> Option.value ~default:"fibonacci_durable_memory_v1";
              trigger =
                {
                  Memory.Compression.Trigger.mode = trigger_mode;
                  reply_checkpoints = trigger_reply_checkpoints;
                  continue_every_replies;
                  fibonacci_first_reply;
                  fibonacci_second_reply;
                };
              budget =
                {
                  Memory.Compression.Budget.mode = budget_mode;
                  base_summary_max_chars;
                  min_summary_max_chars;
                  base_summary_max_tokens;
                  min_summary_max_tokens;
                };
              value_hierarchy;
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
    let discussion =
      match json |> member "discussion" with
      | `Null -> Ok Discussion.disabled
      | (`Assoc _ as discussion_json) -> parse_discussion ~base_dir discussion_json
      | _ ->
          Error "Invalid discussion configuration: expected an object."
    in
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
    (match discussion, memory with
    | (Error _ as error), _ -> error
    | _, (Error _ as error) -> error
    | Ok discussion, Ok memory ->
        Ok
          {
            engine = json |> member "engine" |> parse_engine;
            routing = json |> member "routing" |> parse_routing;
            demo = json |> member "demo" |> parse_demo;
            llm = json |> member "llm" |> parse_llm ~base_dir;
            discussion;
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
