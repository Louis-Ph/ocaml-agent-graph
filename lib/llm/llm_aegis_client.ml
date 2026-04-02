open Lwt.Infix

type usage = {
  prompt_tokens : int;
  completion_tokens : int;
  total_tokens : int;
}

type completion = {
  model : string;
  content : string;
  usage : usage;
}

type t = {
  store : Aegis_lm.Runtime_state.t;
  authorization : string;
  llm_config : Runtime_config.Llm.t;
}

let resolve_authorization llm_config =
  match llm_config.Runtime_config.Llm.authorization_token_plaintext with
  | Some token when String.trim token <> "" -> Ok ("Bearer " ^ token)
  | _ ->
      (match llm_config.authorization_token_env with
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

let create llm_config =
  match resolve_authorization llm_config with
  | Error _ as error -> error
  | Ok authorization ->
      (match Aegis_lm.Config.load llm_config.gateway_config_path with
       | Error message ->
           Error
             (Fmt.str
                "Unable to load AegisLM gateway config %s: %s"
                llm_config.gateway_config_path
                message)
       | Ok gateway_config ->
           (match Aegis_lm.Runtime_state.create_result gateway_config with
            | Error message ->
                Error
                  (Fmt.str
                     "Unable to initialize AegisLM runtime from %s: %s"
                     llm_config.gateway_config_path
                     message)
            | Ok store -> Ok { store; authorization; llm_config }))

let of_store ~authorization llm_config store =
  { store; authorization; llm_config }

let extract_text response =
  response.Aegis_lm.Openai_types.choices
  |> List.filter_map (fun (choice : Aegis_lm.Openai_types.chat_choice) ->
         match String.trim choice.message.content with
         | "" -> None
         | value -> Some value)
  |> String.concat "\n"

let invoke_chat client ~agent ~profile ~context ~payload ~instruction =
  let request =
    Aegis_lm.Openai_types.
      {
        model = profile.Runtime_config.Llm.Agent_profile.model;
        messages =
          Llm_prompt.build_messages ~agent ~profile ~instruction context payload;
        stream = false;
        max_tokens = profile.max_tokens;
      }
  in
  Aegis_lm.Router.dispatch_chat client.store ~authorization:client.authorization request
  >|= function
  | Error err -> Error (Aegis_lm.Domain_error.to_string err)
  | Ok response ->
      Ok
        {
          model = response.model;
          content = extract_text response;
          usage =
            {
              prompt_tokens = response.usage.prompt_tokens;
              completion_tokens = response.usage.completion_tokens;
              total_tokens = response.usage.total_tokens;
            };
        }
