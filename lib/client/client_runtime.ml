type agent_profile_summary = {
  agent_name : string;
  route_model : string;
  max_tokens : int option;
  confidence : float;
  system_prompt_preview : string;
}

type t = {
  client_config_path : string;
  client_config : Client_config.t;
  runtime_config_path : string;
  runtime_config : Runtime_config.t;
  llm_client : Llm_aegis_client.t;
}

let trim_preview ~max_chars text =
  let trimmed = String.trim text in
  if String.length trimmed <= max_chars then trimmed
  else String.sub trimmed 0 max_chars ^ "..."

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
           (match Llm_aegis_client.create runtime_config.llm with
            | Error _ as error -> error
            | Ok llm_client ->
                (match
                   Llm_aegis_client.validate_route_models
                     llm_client
                     [ client_config.assistant.route_model ]
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
  Llm_aegis_client.route_models t.llm_client
  |> List.map (fun route_model ->
         match Llm_aegis_client.route_access t.llm_client ~route_model with
         | Some route_access -> Llm_aegis_client.route_access_summary route_access
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
  [
    Fmt.str "client_config: %s" t.client_config_path;
    Fmt.str "graph_runtime_config: %s" t.runtime_config_path;
    Fmt.str "gateway_config: %s" config.llm.gateway_config_path;
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
      ( "agent_profiles",
        `List
          (agent_profile_summaries config
           |> List.map agent_profile_summary_to_yojson) );
      ( "routes",
        `List (route_summaries t |> List.map (fun value -> `String value)) );
    ]
