let render_metadata metadata =
  match metadata with
  | [] -> "none"
  | _ ->
      metadata
      |> List.map (fun (key, value) -> Fmt.str "%s=%s" key value)
      |> String.concat ", "

let render_history (context : Core_context.t) =
  match List.rev context.Core_context.history with
  | [] -> "none"
  | history ->
      history
      |> List.mapi (fun index (message : Core_message.t) ->
             Fmt.str
               "%d. [%s] %s"
               (index + 1)
               (Core_message.role_to_string message.role)
               message.content)
      |> String.concat "\n"

let render_completed_agents (context : Core_context.t) =
  match Core_context.completed_agent_names context with
  | [] -> "none"
  | names -> String.concat ", " names

let render_user_message ~agent ~instruction (context : Core_context.t) payload =
  Fmt.str
    "Agent: %s\nTask ID: %s\nMetadata: %s\nCompleted agents: %s\n\nHistory:\n%s\n\nCurrent payload:\n%s\n\nInstruction:\n%s"
    (Core_agent_name.to_string agent)
    context.task_id
    (render_metadata context.metadata)
    (render_completed_agents context)
    (render_history context)
    (Core_payload.to_pretty_string payload)
    instruction

let build_messages ~agent ~profile ~instruction context payload :
    Bulkhead_lm.Openai_types.message list =
  let system_message : Bulkhead_lm.Openai_types.message =
    {
      role = "system";
      content = profile.Runtime_config.Llm.Agent_profile.system_prompt;
    }
  in
  let user_message : Bulkhead_lm.Openai_types.message =
    {
      role = "user";
      content = render_user_message ~agent ~instruction context payload;
    }
  in
  [ system_message; user_message ]
