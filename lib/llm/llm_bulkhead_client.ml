open Lwt.Infix

module String_map = Map.Make (String)

type usage = {
  prompt_tokens : int;
  completion_tokens : int;
  total_tokens : int;
}

type readiness =
  | Ready
  | Missing
  | Unknown

type backend_access = {
  provider_id : string;
  provider_kind : string;
  upstream_model : string;
  target : string;
  api_key_env : string;
  readiness : readiness;
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

type transport =
  | Embedded_store of Bulkhead_lm.Runtime_state.t
  | External_http of {
      gateway_endpoint_url : string;
      timeout_seconds : float;
    }

type t = {
  transport : transport;
  authorization : string;
  route_access_by_model : route_access String_map.t;
  default_persistence_sqlite_path : string option;
}

let contains_substring ~substring value =
  let substring_length = String.length substring in
  let value_length = String.length value in
  let rec loop index =
    if index + substring_length > value_length then false
    else if String.sub value index substring_length = substring then true
    else loop (index + 1)
  in
  if substring_length = 0 then true else loop 0

let trim_trailing_slash value =
  if String.ends_with ~suffix:"/" value then
    String.sub value 0 (String.length value - 1)
  else value

let infer_http_provider_kind api_base =
  let normalized_api_base = String.lowercase_ascii api_base in
  if contains_substring ~substring:"openrouter" normalized_api_base
  then "openrouter_openai"
  else "openai_compat"

let provider_kind_to_string (backend : Bulkhead_lm.Config.backend) =
  (match backend.provider_kind with
   | Bulkhead_lm.Config.Openai_compat -> "openai_compat"
   | Bulkhead_lm.Config.Anthropic -> "anthropic"
   | Bulkhead_lm.Config.Google_openai -> "google_openai"
   | Bulkhead_lm.Config.Mistral_openai -> "mistral_openai"
   | Bulkhead_lm.Config.Ollama_openai -> "ollama_openai"
   | Bulkhead_lm.Config.Alibaba_openai -> "alibaba_openai"
   | Bulkhead_lm.Config.Moonshot_openai -> "moonshot_openai"
   | Bulkhead_lm.Config.Bulkhead_peer -> "bulkhead_peer"
   | Bulkhead_lm.Config.Bulkhead_ssh_peer -> "bulkhead_ssh_peer"
   | _ ->
       (match backend.target with
        | Bulkhead_lm.Config.Http_target api_base -> infer_http_provider_kind api_base
        | Bulkhead_lm.Config.Ssh_target _ -> "bulkhead_ssh_peer"))
    [@warning "-11"]

let env_is_ready env_name =
  match Sys.getenv_opt env_name with
  | Some value when String.trim value <> "" -> true
  | _ -> false

let readiness_label = function
  | Ready -> "ready"
  | Missing -> "missing"
  | Unknown -> "external"

let backend_access_of_backend (backend : Bulkhead_lm.Config.backend) =
  {
    provider_id = backend.provider_id;
    provider_kind = provider_kind_to_string backend;
    upstream_model = backend.upstream_model;
    target = Bulkhead_lm.Config.backend_target_label backend;
    api_key_env = backend.api_key_env;
    readiness = if env_is_ready backend.api_key_env then Ready else Missing;
  }

let ready_backend_count backends =
  backends
  |> List.filter (fun backend ->
         match backend.readiness with
         | Ready | Unknown -> true
         | Missing -> false)
  |> List.length

let route_access_of_backends ~route_model backends =
  {
    route_model;
    backends;
    ready_backend_count = ready_backend_count backends;
  }

let route_access_of_route (route : Bulkhead_lm.Config.route) =
  let backends =
    route.backends
    |> List.map backend_access_of_backend
  in
  route_access_of_backends ~route_model:route.public_model backends

let route_access_index_of_store store =
  let config = store.Bulkhead_lm.Runtime_state.config in
  config.routes
  |> List.fold_left
       (fun index route ->
         let route_access = route_access_of_route route in
         String_map.add route_access.route_model route_access index)
       String_map.empty

let json_member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let json_string_opt name json =
  match json_member name json with
  | Some (`String value) when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let json_list name json =
  match json_member name json with
  | Some (`List values) -> values
  | _ -> []

let backend_target_of_catalog_json json =
  match json_member "transport" json with
  | Some transport_json ->
      json_string_opt "target" transport_json
      |> Option.value ~default:"(unknown)"
  | None -> "(unknown)"

let backend_access_of_catalog_json json =
  {
    provider_id =
      json_string_opt "provider_id" json
      |> Option.value ~default:"(unknown-provider)";
    provider_kind =
      json_string_opt "provider_kind" json
      |> Option.value ~default:"(unknown-kind)";
    upstream_model =
      json_string_opt "upstream_model" json
      |> Option.value ~default:"(unknown-model)";
    target = backend_target_of_catalog_json json;
    api_key_env =
      json_string_opt "credential_env" json
      |> Option.value ~default:"(server-managed)";
    readiness = Unknown;
  }

let route_access_of_models_json json =
  let route_model =
    match json_string_opt "public_model" json with
    | Some value -> Some value
    | None -> json_string_opt "id" json
  in
  match route_model with
  | None -> None
  | Some route_model ->
      let backends =
        json_list "configured_backends" json
        |> List.filter_map (function
               | `Assoc _ as backend_json ->
                   Some (backend_access_of_catalog_json backend_json)
               | _ -> None)
      in
      Some (route_access_of_backends ~route_model backends)

let route_access_index_of_models_response json =
  match json_member "data" json with
  | Some (`List values) ->
      values
      |> List.fold_left
           (fun index item ->
             match route_access_of_models_json item with
             | Some route_access ->
                 String_map.add route_access.route_model route_access index
             | None -> index)
           String_map.empty
  | _ -> String_map.empty

let gateway_persistence_sqlite_path gateway_config_path =
  try
    let json = Yojson.Safe.from_file gateway_config_path in
    match json_member "persistence" json with
    | Some persistence_json ->
        json_string_opt "sqlite_path" persistence_json
        |> Option.map (Config_support.resolve_relative_path ~base_dir:(Filename.dirname gateway_config_path))
    | None -> None
  with
  | Sys_error _
  | Yojson.Json_error _
  | Yojson.Safe.Util.Type_error _ -> None

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
    "Unknown BulkheadLM route_model=%s. Available route_models: %s"
    route_model
    available_routes

let ensure_route_model client ~route_model =
  match route_access client ~route_model with
  | None -> Error (missing_route_message client route_model)
  | Some access when access.backends = [] ->
      Error
        (Fmt.str
           "BulkheadLM route_model=%s is configured without any provider backend."
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
                  "Invalid BulkheadLM binding for agent=%s: %s"
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
    (readiness_label backend.readiness)

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

let make ~authorization ~transport ~default_persistence_sqlite_path route_access_by_model =
  {
    transport;
    authorization;
    route_access_by_model;
    default_persistence_sqlite_path;
  }

let default_persistence_sqlite_path client =
  client.default_persistence_sqlite_path

let resolve_authorization ~authorization_token_plaintext ~authorization_token_env =
  match authorization_token_plaintext with
  | Some token when String.trim token <> "" -> Ok ("Bearer " ^ String.trim token)
  | _ ->
      (match authorization_token_env with
       | None ->
           Error
             "LLM authorization is missing. Configure authorization_token_plaintext or authorization_token_env."
       | Some env_name ->
           (match Sys.getenv_opt env_name with
            | Some token when String.trim token <> "" -> Ok ("Bearer " ^ String.trim token)
            | _ ->
                Error
                  (Fmt.str
                     "LLM authorization env var is missing or empty: %s"
                     env_name)))

let response_message response body =
  let status = Cohttp.Response.status response in
  let code = Cohttp.Code.code_of_status status in
  let reason = Cohttp.Code.string_of_status status in
  let trimmed_body = String.trim body in
  if trimmed_body = ""
  then Fmt.str "HTTP %d %s" code reason
  else Fmt.str "HTTP %d %s: %s" code reason trimmed_body

let with_timeout ~timeout_seconds ~timeout_message request =
  let timeout =
    Lwt_unix.sleep timeout_seconds >|= fun () ->
    Error timeout_message
  in
  Lwt.pick [ request; timeout ]

let external_uri gateway_endpoint_url suffix =
  Uri.of_string (trim_trailing_slash gateway_endpoint_url ^ suffix)

let fetch_models_inventory ~authorization ~gateway_config_path ~gateway_endpoint_url =
  let uri = external_uri gateway_endpoint_url "/v1/models" in
  let headers =
    Cohttp.Header.of_list [ "authorization", authorization ]
  in
  let request =
    Lwt.catch
      (fun () ->
         Cohttp_lwt_unix.Client.get ~headers uri >>= fun (response, body) ->
         Cohttp_lwt.Body.to_string body >|= fun body_text ->
         let status = Cohttp.Response.status response in
         if Cohttp.Code.(is_success (code_of_status status))
         then
           try
             let json = Yojson.Safe.from_string body_text in
             Ok (route_access_index_of_models_response json)
           with
           | Yojson.Json_error message ->
               Error
                 (Fmt.str
                    "BulkheadLM /v1/models returned invalid JSON from %s: %s"
                    gateway_endpoint_url
                    message)
         else
           Error
             (Fmt.str
                "BulkheadLM /v1/models failed at %s: %s"
                gateway_endpoint_url
                (response_message response body_text)))
      (fun exn ->
         Lwt.return
           (Error
              (Fmt.str
                 "Unable to contact external BulkheadLM server at %s: %s. Start BulkheadLM with config %s."
                 gateway_endpoint_url
                 (Printexc.to_string exn)
                 gateway_config_path)))
  in
  with_timeout
    ~timeout_seconds:5.0
    ~timeout_message:
      (Fmt.str
         "Timed out while contacting external BulkheadLM server at %s. Start BulkheadLM with config %s."
         gateway_endpoint_url
         gateway_config_path)
    request

let create_with_gateway
    ~gateway_config_path
    ~gateway_endpoint_url
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
      (match
         Lwt_main.run
           (fetch_models_inventory
              ~authorization
              ~gateway_config_path
              ~gateway_endpoint_url)
       with
       | Error _ as error -> error
       | Ok route_access_by_model ->
           Ok
             (make
                ~authorization
                ~transport:
                  (External_http
                     {
                       gateway_endpoint_url;
                       timeout_seconds = 300.0;
                     })
                ~default_persistence_sqlite_path:
                  (gateway_persistence_sqlite_path gateway_config_path)
                route_access_by_model))

let create (llm_config : Runtime_config.Llm.t) =
  create_with_gateway
    ~gateway_config_path:llm_config.gateway_config_path
    ~gateway_endpoint_url:llm_config.gateway_endpoint_url
    ~authorization_token_plaintext:llm_config.authorization_token_plaintext
    ~authorization_token_env:llm_config.authorization_token_env

let of_store ~authorization store =
  make
    ~authorization
    ~transport:(Embedded_store store)
    ~default_persistence_sqlite_path:
      store.Bulkhead_lm.Runtime_state.config.persistence.sqlite_path
    (route_access_index_of_store store)

let extract_text response =
  response.Bulkhead_lm.Openai_types.choices
  |> List.filter_map (fun (choice : Bulkhead_lm.Openai_types.chat_choice) ->
         match String.trim choice.message.content with
         | "" -> None
         | value -> Some value)
  |> String.concat "\n"

let invoke_external_chat
    ~authorization
    ~gateway_endpoint_url
    ~timeout_seconds
    request
  =
  let uri = external_uri gateway_endpoint_url "/v1/chat/completions" in
  let headers =
    Cohttp.Header.of_list
      [ "authorization", authorization; "content-type", "application/json" ]
  in
  let body =
    request
    |> Bulkhead_lm.Openai_types.chat_request_to_yojson
    |> Yojson.Safe.to_string
    |> Cohttp_lwt.Body.of_string
  in
  let request_lwt =
    Lwt.catch
      (fun () ->
         Cohttp_lwt_unix.Client.post ~headers ~body uri >>= fun (response, body) ->
         Cohttp_lwt.Body.to_string body >|= fun body_text ->
         let status = Cohttp.Response.status response in
         if Cohttp.Code.(is_success (code_of_status status))
         then
           try
             let json = Yojson.Safe.from_string body_text in
             match Bulkhead_lm.Openai_types.chat_response_of_yojson json with
             | Ok response -> Ok response
             | Error field ->
                 Error
                   (Fmt.str
                      "BulkheadLM external chat response is missing field %s."
                      field)
           with
           | Yojson.Json_error message ->
               Error
                 (Fmt.str
                    "BulkheadLM external chat response is invalid JSON: %s"
                    message)
         else Error (response_message response body_text))
      (fun exn ->
         Lwt.return
           (Error
              (Fmt.str
                 "External BulkheadLM chat request failed at %s: %s"
                 gateway_endpoint_url
                 (Printexc.to_string exn))))
  in
  with_timeout
    ~timeout_seconds
    ~timeout_message:
      (Fmt.str
         "External BulkheadLM chat request timed out after %.1fs at %s."
         timeout_seconds
         gateway_endpoint_url)
    request_lwt

let invoke_messages client ~route_model ~messages ~max_tokens =
  match ensure_route_model client ~route_model with
  | Error _ as error -> Lwt.return error
  | Ok route_access ->
      let request =
        Bulkhead_lm.Openai_types.
          { model = route_model; messages; stream = false; max_tokens; extra = [] }
      in
      let response_lwt =
        match client.transport with
        | Embedded_store store ->
            (Bulkhead_lm.Router.dispatch_chat
               store
               ~authorization:client.authorization
               request
             >|= function
             | Error err -> Error (Bulkhead_lm.Domain_error.to_string err)
             | Ok response -> Ok response)
        | External_http { gateway_endpoint_url; timeout_seconds } ->
            invoke_external_chat
              ~authorization:client.authorization
              ~gateway_endpoint_url
              ~timeout_seconds
              request
      in
      response_lwt
      >|= function
      | Error _ as error -> error
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
