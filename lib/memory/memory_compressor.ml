open Lwt.Infix

let role_label = function
  | Memory_store.User -> "user"
  | Assistant -> "assistant"

let trim_summary max_chars text =
  let trimmed = String.trim text in
  if max_chars <= 0 || String.length trimmed <= max_chars
  then trimmed
  else String.sub trimmed 0 (max_chars - 3) ^ "..."

let turn_line (turn : Memory_store.turn) =
  Fmt.str "%d. [%s] %s" turn.turn_index (role_label turn.role) turn.content

let fallback_summary
    ~(summary_max_chars : int)
    ~(existing_summary : string option)
    ~(turns : Memory_store.turn list)
  =
  let blocks =
    [
      Option.map
        (fun summary -> "Existing durable summary:\n" ^ summary)
        existing_summary;
      Some
        ("New conversation turns:\n"
        ^ (turns |> List.map turn_line |> String.concat "\n"));
    ]
    |> List.filter_map Fun.id
  in
  trim_summary summary_max_chars (String.concat "\n\n" blocks)

let compression_prompt
    ~(compression : Runtime_config.Memory.Compression.t)
    ~(plan : Memory_policy.plan)
    ~(existing_summary : string option)
    ~(turns : Memory_store.turn list)
  =
  Fmt.str
    "%s\n\nCompression policy: %s.\nCheckpoint matched: reply %d.\nTarget budget: about \
     %d%% of the base memory budget, capped at %d chars and %s tokens.\n\nMemory value \
     hierarchy:\n%s\n\nExisting durable summary:\n%s\n\nNew conversation turns to \
     absorb:\n%s\n\nReturn one compact memory note that preserves the high-value tiers \
     first, compresses lower-value detail aggressively, and keeps stable facts, goals, \
     constraints, names, preferences, decisions, blockers, and unresolved items."
    compression.summary_prompt
    compression.policy_name
    plan.checkpoint_reply_count
    plan.budget.target_percent
    plan.budget.target_summary_max_chars
    (match plan.budget.target_summary_max_tokens with
     | Some value -> string_of_int value
     | None -> "the agent default")
    (Memory_policy.render_value_hierarchy compression.value_hierarchy)
    (Option.value existing_summary ~default:"(none)")
    (turns |> List.map turn_line |> String.concat "\n")

let compress_history
    ~(llm_client : Llm_bulkhead_client.t)
    ~(profile : Runtime_config.Llm.Agent_profile.t)
    ~(compression : Runtime_config.Memory.Compression.t)
    ~(plan : Memory_policy.plan)
    ~(existing_summary : string option)
    ~(turns : Memory_store.turn list)
  =
  match turns with
  | [] ->
      Lwt.return (Option.value existing_summary ~default:"")
  | _ ->
      let messages : Bulkhead_lm.Openai_types.message list =
        [
          { role = "system"; content = profile.system_prompt };
          {
            role = "user";
            content =
              compression_prompt
                ~compression
                ~plan
                ~existing_summary
                ~turns;
          };
        ]
      in
      Llm_bulkhead_client.invoke_messages
        llm_client
        ~route_model:profile.route_model
        ~messages
        ~max_tokens:
          (match plan.budget.target_summary_max_tokens with
          | Some _ as value -> value
          | None -> profile.max_tokens)
      >|= function
      | Ok completion ->
          let summary =
            match String.trim completion.content with
            | "" ->
                fallback_summary
                  ~summary_max_chars:plan.budget.target_summary_max_chars
                  ~existing_summary
                  ~turns
            | value -> trim_summary plan.budget.target_summary_max_chars value
          in
          summary
      | Error _ ->
          fallback_summary
            ~summary_max_chars:plan.budget.target_summary_max_chars
            ~existing_summary
            ~turns
