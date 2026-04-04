open Lwt.Infix

module String_map = Map.Make (String)

type usage = {
  prompt_tokens : int;
  completion_tokens : int;
  total_tokens : int;
}

type backend_access = {
  provider_id : string;
  provider_kind : string;
  upstream_model : string;
  target : string;
  api_key_env : string;
  ready : bool;
}

type route_access = {
  route_model : string;
  backends : backend_access list;
  ready_backend_count : int;
}

type completion = {
  route_model : string;
  model : string;
  content : string;
  usage : usage;
  route_access : route_access;
}

type t = {
  store : Aegis_lm.Runtime_state.t;
  authorization : string;
  route_access_by_model : route_access String_map.t;
}

let provider_kind_to_string = function
  | Aegis_lm.Config.Openai_compat -> "openai_compat"
  | Aegis_lm.Config.Anthropic -> "anthropic"
  | Aegis_lm.Config.Google_openai -> "google_openai"
  | Aegis_lm.Config.Mistral_openai -> "mistral_openai"
  | Aegis_lm.Config.Ollama_openai -> "ollama_openai"
  | Aegis_lm.Config.Alibaba_openai -> "alibaba_openai"
  | Aegis_lm.Config.Moonshot_openai -> "moonshot_openai"
  | Aegis_lm.Config.Aegis_peer -> "aegis_peer"
  | Aegis_lm.Config.Aegis_ssh_peer -> "aegis_ssh_peer"

let env_is_ready env_name =
  match Sys.getenv_opt env_name with
  | Some value when String.trim value <> "" -> true
  | _ -> false

let backend_access_of_backend (backend : Aegis_lm.Config.backend) =
  {
    provider_id = backend.provider_id;
    provider_kind = provider_kind_to_string backend.provider_kind;
    upstream_model = backend.upstream_model;
    target = Aegis_lm.Config.backend_target_label backend;
    api_key_env = backend.api_key_env;
    ready = env_is_ready backend.api_key_env;
  }

let route_access_of_route (route : Aegis_lm.Config.route) =
  let backends =
    route.backends
    |> List.map backend_access_of_backend
  in
  let ready_backend_count =
    backends |> List.filter (fun backend -> backend.ready) |> List.length
  in
  {
    route_model = route.public_model;
    backends;
    ready_backend_count;
  }

let route_access_index store =
  let config = store.Aegis_lm.Runtime_state.config in
  config.routes
  |> List.fold_left
       (fun index route ->
         let route_access = route_access_of_route route in
         String_map.add route_access.route_model route_access index)
       String_map.empty

let route_models client =
  client.route_access_by_model
  |> String_map.bindings
  |> List.map fst
  |> List.sort String.compare

let route_access client ~route_model =
  String_map.find_opt route_model client.route_access_by_model

let missing_route_message client route_model =
  let available_routes =
    match route_models client with
    | [] -> "(none)"
    | models -> String.concat ", " models
  in
  Fmt.str
    "Unknown AegisLM route_model=%s. Available route_models: %s"
    route_model
    available_routes

let ensure_route_model client ~route_model =
  match route_access client ~route_model with
  | None -> Error (missing_route_message client route_model)
  | Some access when access.backends = [] ->
      Error
        (Fmt.str
           "AegisLM route_model=%s is configured without any provider backend."
           route_model)
  | Some access -> Ok access

let validate_route_models client route_models =
  let unique_route_models = List.sort_uniq String.compare route_models in
  let rec loop = function
    | [] -> Ok ()
    | route_model :: rest ->
        (match ensure_route_model client ~route_model with
         | Ok _ -> loop rest
         | Error _ as error -> error)
  in
  loop unique_route_models

let validate_agent_profiles client (llm_config : Runtime_config.Llm.t) =
  let rec loop = function
    | [] -> Ok ()
    | (agent, profile) :: rest ->
        let profile : Runtime_config.Llm.Agent_profile.t = profile in
        (match ensure_route_model client ~route_model:profile.route_model with
         | Ok _ -> loop rest
         | Error message ->
             Error
               (Fmt.str
                  "Invalid AegisLM binding for agent=%s: %s"
                  (Core_agent_name.to_string agent)
                  message))
  in
  loop (Runtime_config.Llm.agent_bindings llm_config)

let backend_access_summary (backend : backend_access) =
  Fmt.str
    "%s [%s -> %s | target=%s | env=%s:%s]"
    backend.provider_id
    backend.provider_kind
    backend.upstream_model
    backend.target
    backend.api_key_env
    (if backend.ready then "ready" else "missing")

let route_access_summary (route_access : route_access) =
  Fmt.str
    "route_model=%s ready_backends=%d/%d backends=%s"
    route_access.route_model
    route_access.ready_backend_count
    (List.length route_access.backends)
    (match route_access.backends with
     | [] -> "(none)"
     | backends ->
         backends
         |> List.map backend_access_summary
         |> String.concat "; ")

let make ~authorization store =
  {
    store;
    authorization;
    route_access_by_model = route_access_index store;
  }

let resolve_authorization ~authorization_token_plaintext ~authorization_token_env =
  match authorization_token_plaintext with
  | Some token when String.trim token <> "" -> Ok ("Bearer " ^ token)
  | _ ->
      (match authorization_token_env with
       | None ->
           Error
             "LLM authorization is missing. Configure authorization_token_plaintext or authorization_token_env."
       | Some env_name ->
           (match Sys.getenv_opt env_name with
            | Some token when String.trim token <> "" -> Ok ("Bearer " ^ token)
            | _ ->
                Error
                  (Fmt.str
                     "LLM authorization env var is missing or empty: %s"
                     env_name)))

let create_with_gateway
    ~gateway_config_path
    ~authorization_token_plaintext
    ~authorization_token_env
  =
  match
    resolve_authorization
      ~authorization_token_plaintext
      ~authorization_token_env
  with
  | Error _ as error -> error
  | Ok authorization ->
      (match Aegis_lm.Config.load gateway_config_path with
       | Error message ->
           Error
             (Fmt.str
                "Unable to load AegisLM gateway config %s: %s"
                gateway_config_path
                message)
       | Ok gateway_config ->
           (match Aegis_lm.Runtime_state.create_result gateway_config with
            | Error message ->
                Error
                  (Fmt.str
                     "Unable to initialize AegisLM runtime from %s: %s"
                     gateway_config_path
                     message)
            | Ok store -> Ok (make ~authorization store)))

let create (llm_config : Runtime_config.Llm.t) =
  create_with_gateway
    ~gateway_config_path:llm_config.gateway_config_path
    ~authorization_token_plaintext:llm_config.authorization_token_plaintext
    ~authorization_token_env:llm_config.authorization_token_env

let of_store ~authorization store = make ~authorization store

let extract_text response =
  response.Aegis_lm.Openai_types.choices
  |> List.filter_map (fun (choice : Aegis_lm.Openai_types.chat_choice) ->
         match String.trim choice.message.content with
         | "" -> None
         | value -> Some value)
  |> String.concat "\n"

let invoke_messages client ~route_model ~messages ~max_tokens =
  match ensure_route_model client ~route_model with
  | Error _ as error -> Lwt.return error
  | Ok route_access ->
      let request =
        Aegis_lm.Openai_types.
          { model = route_model; messages; stream = false; max_tokens }
      in
      Aegis_lm.Router.dispatch_chat client.store ~authorization:client.authorization request
      >|= function
      | Error err -> Error (Aegis_lm.Domain_error.to_string err)
      | Ok response ->
          Ok
            {
              route_model;
              model = response.model;
              content = extract_text response;
              usage =
                {
                  prompt_tokens = response.usage.prompt_tokens;
                  completion_tokens = response.usage.completion_tokens;
                  total_tokens = response.usage.total_tokens;
                };
              route_access;
            }

let invoke_chat client ~agent ~profile ~context ~payload ~instruction =
  invoke_messages
    client
    ~route_model:profile.Runtime_config.Llm.Agent_profile.route_model
    ~messages:(Llm_prompt.build_messages ~agent ~profile ~instruction context payload)
    ~max_tokens:profile.max_tokens
