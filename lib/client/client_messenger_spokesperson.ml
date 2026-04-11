open Lwt.Infix

type run_result = {
  task_id : string;
  input : string;
  payload : Core_payload.t;
  context : Core_context.t;
}

let take_last count items =
  let rec drop excess values =
    if excess <= 0 then values
    else
      match values with
      | [] -> []
      | _ :: rest -> drop (excess - 1) rest
  in
  let length = List.length items in
  drop (max 0 (length - count)) items

let non_system_messages messages =
  messages
  |> List.filter (fun (message : Bulkhead_lm.Openai_types.message) ->
         not (String.equal (String.lowercase_ascii message.role) "system"))

let latest_user_content messages =
  messages
  |> List.rev
  |> List.find_map (fun (message : Bulkhead_lm.Openai_types.message) ->
         if String.equal (String.lowercase_ascii message.role) "user" then
           let content = String.trim message.content in
           if content = "" then None else Some content
         else None)

let conversation_excerpt messages =
  non_system_messages messages
  |> take_last 8
  |> List.filter_map (fun (message : Bulkhead_lm.Openai_types.message) ->
         let content = String.trim message.content in
         if content = "" then None
         else Some (Fmt.str "%s: %s" message.role content))
  |> String.concat "\n"

let graph_input_of_messages messages =
  match latest_user_content messages with
  | None ->
      Error
        "Messenger spokesperson requests require at least one non-empty user message."
  | Some latest_request ->
      let transcript = conversation_excerpt messages in
      if transcript = "" then Ok latest_request
      else
        Ok
          (Fmt.str
             "Client conversation transcript:\n%s\n\nLatest client request:\n%s"
             transcript
             latest_request)

let current_task_id () =
  Fmt.str "messenger-%d" (int_of_float (Unix.gettimeofday () *. 1000.0))

let run_swarm (runtime : Client_runtime.t) input =
  let services =
    Runtime_services.of_llm_client
      ~config:runtime.Client_runtime.runtime_config
      runtime.llm_client
  in
  let registry = Default_agents.make_registry () in
  let task_id = current_task_id () in
  let context =
    Core_context.empty
      ~task_id
      ~metadata:[ "origin", "messenger_spokesperson" ]
  in
  Orchestration_orchestrator.loop
    ~services
    ~config:runtime.runtime_config
    ~registry
    context
    (Core_payload.Text input)
  >|= fun (payload, context) -> { task_id; input; payload; context }

let render_recent_events (context : Core_context.t) =
  context.events
  |> List.rev
  |> take_last 6
  |> List.map (fun (event : Core_context.event) ->
         Fmt.str "- step=%d label=%s detail=%s"
           event.step_index event.label event.detail)
  |> String.concat "\n"

let spokesperson_prompt
    (request : Bulkhead_lm.Openai_types.chat_request)
    (result : run_result)
  =
  let transcript = conversation_excerpt request.messages in
  let completed_agents =
    Core_context.completed_agent_names result.context |> String.concat ", "
  in
  let recent_events = render_recent_events result.context in
  Fmt.str
    "You are preparing the single client-facing reply for a swarm execution.\n\n\
     Client conversation excerpt:\n%s\n\n\
     Swarm task input:\n%s\n\n\
     Swarm payload summary:\n%s\n\n\
     Swarm payload details:\n%s\n\n\
     Completed agents:\n%s\n\
     Step count: %d\n\
     Recent orchestration events:\n%s\n\n\
     Write the final reply for the client in one coherent voice. Keep it faithful \
     to the swarm result. Do not mention internal route models, provider backends, \
     OCaml module names, or hidden orchestration machinery unless the client \
     explicitly asks for internals."
    (if transcript = "" then "(none)" else transcript)
    result.input
    (Core_payload.summary result.payload)
    (Core_payload.to_pretty_string result.payload)
    (if completed_agents = "" then "(none)" else completed_agents)
    result.context.step_count
    (if recent_events = "" then "(none)" else recent_events)

let zero_usage =
  Bulkhead_lm.Openai_types.
    { prompt_tokens = 0; completion_tokens = 0; total_tokens = 0 }

let response_id () =
  Fmt.str "chatcmpl-swarm-%d" (int_of_float (Unix.gettimeofday () *. 1000.0))

let response_created () = int_of_float (Unix.gettimeofday ())

let chat_response ~model ~content ~usage =
  Bulkhead_lm.Openai_types.
    {
      id = response_id ();
      created = response_created ();
      model;
      choices =
        [
          {
            index = 0;
            message = { role = "assistant"; content };
            finish_reason = "stop";
          };
        ];
      usage;
    }

let fallback_content (result : run_result) =
  match String.trim (Core_payload.to_pretty_string result.payload) with
  | "" ->
      "The swarm has processed the request, but the spokesperson could not \
       format the final reply."
  | value -> value

let config (runtime : Client_runtime.t) =
  runtime.Client_runtime.client_config.messenger_spokesperson

let expected_authorization
    (config : Client_config.Messenger_spokesperson.t)
  =
  match config.authorization_token_plaintext, config.authorization_token_env with
  | None, None -> Ok None
  | authorization_token_plaintext, authorization_token_env ->
      Llm_bulkhead_client.resolve_authorization
        ~authorization_token_plaintext
        ~authorization_token_env
      |> Result.map Option.some

let models_json (runtime : Client_runtime.t) =
  let models =
    match config runtime with
    | None -> []
    | Some value ->
        [
          `Assoc
            [
              "id", `String value.public_model;
              "object", `String "model";
            ];
        ]
  in
  `Assoc [ "object", `String "list"; "data", `List models ]

let capabilities_json (runtime : Client_runtime.t) =
  match config runtime with
  | None -> `Assoc [ "enabled", `Bool false ]
  | Some value ->
      `Assoc
        [
          "enabled", `Bool true;
          "public_model", `String value.public_model;
          "route_model", `String value.route_model;
          ( "max_tokens",
            match value.max_tokens with
            | Some max_tokens -> `Int max_tokens
            | None -> `Null );
          "api_base", `String (Client_runtime.messenger_api_base runtime.client_config);
          "chat_completions_url",
          `String
            (Client_runtime.messenger_chat_completions_url runtime.client_config);
        ]

let respond
    (runtime : Client_runtime.t)
    (request : Bulkhead_lm.Openai_types.chat_request)
  =
  match config runtime with
  | None ->
      Lwt.return
        (Error
           "Messenger spokesperson is not configured in the client configuration.")
  | Some config ->
      if not (String.equal request.model config.public_model) then
        Lwt.return
          (Error
             (Fmt.str
                "Unknown messenger spokesperson model %s. Expected %s."
                request.model
                config.public_model))
      else if request.stream then
        Lwt.return
          (Error
             "Streaming is not supported for messenger spokesperson requests.")
      else
        match graph_input_of_messages request.messages with
        | Error _ as error -> Lwt.return error
        | Ok input ->
            run_swarm runtime input >>= fun result ->
            let prompt = spokesperson_prompt request result in
            let messages : Bulkhead_lm.Openai_types.message list =
              [
                { role = "system"; content = config.system_prompt };
                { role = "user"; content = prompt };
              ]
            in
            Llm_bulkhead_client.invoke_messages
              runtime.llm_client
              ~route_model:config.route_model
              ~messages
              ~max_tokens:config.max_tokens
            >|= function
            | Ok completion ->
                let content =
                  match String.trim completion.content with
                  | "" -> fallback_content result
                  | value -> value
                in
                Ok
                  (chat_response
                     ~model:config.public_model
                     ~content
                     ~usage:
                       Bulkhead_lm.Openai_types.
                         {
                           prompt_tokens = completion.usage.prompt_tokens;
                           completion_tokens = completion.usage.completion_tokens;
                           total_tokens = completion.usage.total_tokens;
                         })
            | Error message ->
                Runtime_logger.log
                  Runtime_logger.Warning
                  (Fmt.str
                     "Messenger spokesperson fallback used after narration error: %s"
                     message);
                Ok
                  (chat_response
                     ~model:config.public_model
                     ~content:(fallback_content result)
                     ~usage:zero_usage)
