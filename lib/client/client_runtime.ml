type agent_profile_summary = {
  agent_name : string;
  route_model : string;
  max_tokens : int option;
  confidence : float;
  system_prompt_preview : string;
}

type messenger_spokesperson_summary = {
  public_model : string;
  route_model : string;
  max_tokens : int option;
  authorization_summary : string;
}

type t = {
  client_config_path : string;
  client_config : Client_config.t;
  runtime_config_path : string;
  runtime_config : Runtime_config.t;
  llm_client : Llm_bulkhead_client.t;
}

let trim_preview ~max_chars text =
  let trimmed = String.trim text in
  if String.length trimmed <= max_chars then trimmed
  else String.sub trimmed 0 max_chars ^ "..."

let trim_trailing_slash value =
  if String.ends_with ~suffix:"/" value then
    String.sub value 0 (String.length value - 1)
  else value

let messenger_api_base (client_config : Client_config.t) =
  trim_trailing_slash client_config.transport.http.workflow.base_url
  ^ Client_config.Defaults.default_messenger_api_path

let messenger_chat_completions_url (client_config : Client_config.t) =
  messenger_api_base client_config ^ "/chat/completions"

let messenger_authorization_summary
    (config : Client_config.Messenger_spokesperson.t)
  =
  match config.authorization_token_plaintext, config.authorization_token_env with
  | Some _, _ -> "inline-token"
  | None, Some env_name -> Fmt.str "env:%s" env_name
  | None, None -> "open"

let memory_storage_summary (memory : Runtime_config.Memory.t) =
  match memory.storage.mode, memory.storage.sqlite_path with
  | Runtime_config.Memory.Storage.Bulkhead_gateway_sqlite, _ ->
      "bulkhead_gateway_sqlite"
  | Explicit_sqlite, Some path -> "explicit_sqlite:" ^ path
  | Explicit_sqlite, None -> "explicit_sqlite:(missing path)"

let agent_profile_summaries (runtime_config : Runtime_config.t) =
  Runtime_config.Llm.agent_bindings runtime_config.llm
  |> List.map (fun (agent, profile) ->
         let profile : Runtime_config.Llm.Agent_profile.t = profile in
         {
           agent_name = Core_agent_name.to_string agent;
           route_model = profile.route_model;
           max_tokens = profile.max_tokens;
           confidence = profile.confidence;
           system_prompt_preview =
             trim_preview ~max_chars:120 profile.system_prompt;
         })

let messenger_spokesperson_summary (client_config : Client_config.t) =
  match client_config.messenger_spokesperson with
  | None -> None
  | Some config ->
      Some
        {
          public_model = config.public_model;
          route_model = config.route_model;
          max_tokens = config.max_tokens;
          authorization_summary = messenger_authorization_summary config;
        }

let required_route_models (client_config : Client_config.t) =
  let base = [ client_config.assistant.route_model ] in
  match client_config.messenger_spokesperson with
  | None -> base
  | Some config -> config.route_model :: base

let load path =
  match Client_config.load path with
  | Error _ as error -> error
  | Ok client_config ->
      (match Runtime_config.load client_config.graph_runtime_path with
       | Error message ->
           Error
             (Fmt.str
                "Unable to load graph runtime config %s: %s"
                client_config.graph_runtime_path
                message)
       | Ok runtime_config ->
           (match Llm_bulkhead_client.create runtime_config.llm with
            | Error _ as error -> error
            | Ok llm_client ->
                (match
                   Llm_bulkhead_client.validate_route_models
                     llm_client
                     (required_route_models client_config)
                 with
                 | Error _ as error -> error
                 | Ok () ->
                     Ok
                       {
                         client_config_path = path;
                         client_config;
                         runtime_config_path = client_config.graph_runtime_path;
                         runtime_config;
                         llm_client;
                       })))

let of_parts
    ~client_config_path
    ~client_config
    ~runtime_config_path
    ~runtime_config
    ~llm_client
  =
  {
    client_config_path;
    client_config;
    runtime_config_path;
    runtime_config;
    llm_client;
  }

let route_summaries t =
  Llm_bulkhead_client.route_models t.llm_client
  |> List.map (fun route_model ->
         match Llm_bulkhead_client.route_access t.llm_client ~route_model with
         | Some route_access -> Llm_bulkhead_client.route_access_summary route_access
         | None -> Fmt.str "route_model=%s is unavailable" route_model)

let graph_summary_lines t =
  let config = t.runtime_config in
  let routing = config.routing in
  let engine = config.engine in
  let agent_lines =
    agent_profile_summaries config
    |> List.map (fun summary ->
           Fmt.str
             "- %s -> route_model=%s max_tokens=%s confidence=%.2f prompt=%s"
             summary.agent_name
             summary.route_model
             (match summary.max_tokens with
              | Some value -> string_of_int value
              | None -> "none")
             summary.confidence
             summary.system_prompt_preview)
  in
  let route_lines = route_summaries t |> List.map (fun line -> "- " ^ line) in
  let memory_lines =
    if not config.memory.enabled then [ "memory: disabled" ]
    else
      [
        Fmt.str
          "memory: namespace=%s storage=%s recent_turn_buffer=%d checkpoints=%s"
          config.memory.session_namespace
          (memory_storage_summary config.memory)
          config.memory.reload.recent_turn_buffer
          (config.memory.compression.reply_checkpoints
           |> List.map string_of_int
           |> String.concat ", ");
      ]
  in
  let messenger_lines =
    match messenger_spokesperson_summary t.client_config with
    | None -> [ "messenger_spokesperson: disabled" ]
    | Some summary ->
        [
          Fmt.str
            "messenger_spokesperson: public_model=%s route_model=%s max_tokens=%s auth=%s"
            summary.public_model
            summary.route_model
            (match summary.max_tokens with
             | Some value -> string_of_int value
             | None -> "none")
            summary.authorization_summary;
          Fmt.str
            "messenger_chat_completions: %s"
            (messenger_chat_completions_url t.client_config);
        ]
  in
  [
    Fmt.str "client_config: %s" t.client_config_path;
    Fmt.str "graph_runtime_config: %s" t.runtime_config_path;
    Fmt.str "gateway_config: %s" config.llm.gateway_config_path;
    Fmt.str
      "transport: ssh_human=%s"
      t.client_config.transport.ssh.human_remote_command;
    Fmt.str
      "transport: ssh_machine=%s"
      t.client_config.transport.ssh.machine_remote_command;
    Fmt.str
      "transport: http_workflow=%s"
      t.client_config.transport.http.workflow.base_url;
    Fmt.str
      "transport: http_install=%s"
      t.client_config.transport.http.distribution.install_url;
    Fmt.str
      "engine: timeout=%.2fs retries=%d backoff=%.2fs max_steps=%d"
      engine.timeout_seconds
      engine.retry_attempts
      engine.retry_backoff_seconds
      engine.max_steps;
    Fmt.str
      "routing: long_text_threshold=%d short=%s planner=%s parallel=%s"
      routing.long_text_threshold
      (Core_agent_name.to_string routing.short_text_agent)
      (Core_agent_name.to_string routing.planner_agent)
      (routing.parallel_agents
       |> List.map Core_agent_name.to_string
       |> String.concat ", ");
    Fmt.str "assistant_route_model: %s" t.client_config.assistant.route_model;
    "messenger:";
  ]
  @ memory_lines
  @ messenger_lines
  @ [
    "agent_profiles:";
  ]
  @ agent_lines
  @ ("routes:" :: route_lines)

let graph_summary_text t = String.concat "\n" (graph_summary_lines t)

let agent_profile_summary_to_yojson summary =
  `Assoc
    [
      "agent_name", `String summary.agent_name;
      "route_model", `String summary.route_model;
      ( "max_tokens",
        match summary.max_tokens with
        | Some value -> `Int value
        | None -> `Null );
      "confidence", `Float summary.confidence;
      "system_prompt_preview", `String summary.system_prompt_preview;
    ]

let graph_summary_to_yojson t =
  let config = t.runtime_config in
  let routing = config.routing in
  let engine = config.engine in
  `Assoc
    [
      "client_config_path", `String t.client_config_path;
      "graph_runtime_path", `String t.runtime_config_path;
      "gateway_config_path", `String config.llm.gateway_config_path;
      ( "transport",
        `Assoc
          [
            ( "ssh",
              `Assoc
                [
                  ( "human_remote_command",
                    `String t.client_config.transport.ssh.human_remote_command );
                  ( "machine_remote_command",
                    `String t.client_config.transport.ssh.machine_remote_command );
                  ( "install_emit_command",
                    `String t.client_config.transport.ssh.install_emit_command );
                ] );
            ( "http",
              `Assoc
                [
                  ( "workflow",
                    `Assoc
                      [
                        ( "base_url",
                          `String t.client_config.transport.http.workflow.base_url );
                        ( "server_command",
                          `String t.client_config.transport.http.workflow.server_command );
                      ] );
                  ( "distribution",
                    `Assoc
                      [
                        ( "base_url",
                          `String t.client_config.transport.http.distribution.base_url );
                        ( "server_command",
                          `String
                            t.client_config.transport.http.distribution.server_command );
                        ( "install_url",
                          `String t.client_config.transport.http.distribution.install_url );
                        ( "archive_url",
                          `String t.client_config.transport.http.distribution.archive_url );
                      ] );
                ] );
          ] );
      ( "engine",
        `Assoc
          [
            "timeout_seconds", `Float engine.timeout_seconds;
            "retry_attempts", `Int engine.retry_attempts;
            "retry_backoff_seconds", `Float engine.retry_backoff_seconds;
            "max_steps", `Int engine.max_steps;
          ] );
      ( "routing",
        `Assoc
          [
            "long_text_threshold", `Int routing.long_text_threshold;
            "short_text_agent", `String (Core_agent_name.to_string routing.short_text_agent);
            "planner_agent", `String (Core_agent_name.to_string routing.planner_agent);
            ( "parallel_agents",
              `List
                (routing.parallel_agents
                 |> List.map Core_agent_name.to_string
                 |> List.map (fun value -> `String value)) );
          ] );
      "assistant_route_model", `String t.client_config.assistant.route_model;
      ( "messenger_spokesperson",
        match messenger_spokesperson_summary t.client_config with
        | None -> `Null
        | Some summary ->
            `Assoc
              [
                "public_model", `String summary.public_model;
                "route_model", `String summary.route_model;
                ( "max_tokens",
                  match summary.max_tokens with
                  | Some value -> `Int value
                  | None -> `Null );
                "authorization", `String summary.authorization_summary;
                "api_base", `String (messenger_api_base t.client_config);
                "chat_completions_url",
                `String (messenger_chat_completions_url t.client_config);
              ] );
      ( "agent_profiles",
        `List
          (agent_profile_summaries config
           |> List.map agent_profile_summary_to_yojson) );
      ( "routes",
        `List (route_summaries t |> List.map (fun value -> `String value)) );
    ]
