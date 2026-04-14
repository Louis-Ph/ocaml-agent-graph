open Lwt.Syntax

module Event_label = struct
  let started = "discussion.started"
  let failed = "discussion.failed"
  let round_started = "discussion.round.started"
  let turn_failed = "discussion.turn.failed"
  let turn_skipped = "discussion.turn.skipped"
end

module Live_output = struct
  let indent_prefix = "    "

  let indent_block content =
    content
    |> String.split_on_char '\n'
    |> List.map (fun line -> indent_prefix ^ line)
    |> String.concat "\n"

  let participant_names participants =
    participants
    |> List.map (fun (participant : Runtime_config.Discussion.Participant.t) ->
           participant.name)
    |> String.concat ", "

  let started_message (config : Runtime_config.Discussion.t) =
    Fmt.str
      "Discussion started: rounds=%d final_agent=%s participants=%s"
      config.rounds
      (Core_agent_name.to_string config.final_agent)
      (participant_names config.participants)

  let round_started_message ~round_index ~max_rounds ~participants =
    Fmt.str
      "Discussion round %d/%d started with %s"
      round_index
      max_rounds
      (participant_names participants)

  let round_completed_message ~round_index ~max_rounds ~turn_count =
    Fmt.str
      "Discussion round %d/%d completed with %d turn(s)"
      round_index
      max_rounds
      turn_count

  let turn_completed_message ~max_rounds (turn : Core_payload.discussion_turn) =
    Fmt.str
      "Discussion turn %d/%d speaker=%s\n%s"
      turn.round_index
      max_rounds
      turn.speaker
      (indent_block turn.content)

  let turn_failed_message ~round_index ~max_rounds ~speaker ~error =
    Fmt.str
      "Discussion turn %d/%d speaker=%s failed: %s"
      round_index
      max_rounds
      speaker
      error

  let turn_skipped_message ~round_index ~max_rounds ~speaker ~route_model ~ready_backends =
    Fmt.str
      "Discussion turn %d/%d speaker=%s skipped: empty completion (route_model=%s ready_backends=%d)"
      round_index
      max_rounds
      speaker
      route_model
      ready_backends

  let budget_exhausted_message ~collected_turns ~message =
    Fmt.str
      "Discussion halted: budget exhausted after %d turn(s) collected. %s"
      collected_turns
      message

  let unready_route_message ~participant_name ~route_model =
    Fmt.str
      "Discussion participant %s: route_model=%s has no ready backends — all API keys missing, turns will return empty"
      participant_name
      route_model
end

module Prompt_templates = struct
  let max_contribution_words = 120

  let versioned_block label = function
    | None -> None
    | Some (entry : Runtime_config.Discussion.Versioned_text.t) ->
        Some
          (Fmt.str
             "%s (version %s)\n%s"
             label
             entry.version
             entry.text)

  let render_system_prompt
      (participant : Runtime_config.Discussion.Participant.t)
    =
    [
      Some participant.profile.Runtime_config.Llm.Agent_profile.system_prompt;
      versioned_block "Persona" participant.persona;
      versioned_block "Rules" participant.rules;
    ]
    |> List.filter_map (fun value ->
           value
           |> Option.map String.trim
           |> function
           | Some "" | None -> None
           | Some rendered -> Some rendered)
    |> String.concat "\n\n"

  let render_metadata metadata =
    match metadata with
    | [] -> "none"
    | _ ->
        metadata
        |> List.map (fun (key, value) -> Fmt.str "%s=%s" key value)
        |> String.concat ", "

  let render_agenda agenda =
    match agenda with
    | [] -> "none"
    | _ ->
        agenda
        |> List.mapi (fun index step -> Fmt.str "%d. %s" (index + 1) step)
        |> String.concat "\n"

  let render_transcript turns =
    match turns with
    | [] -> "none yet"
    | _ ->
        turns
        |> List.map (fun (turn : Core_payload.discussion_turn) ->
               Fmt.str
                 "Round %d | %s\n%s"
                 turn.round_index
                 turn.speaker
                 turn.content)
        |> String.concat "\n\n"

  let build_messages
      ~(participant : Runtime_config.Discussion.Participant.t)
      ~(context : Core_context.t)
      ~(discussion : Core_payload.discussion)
      ~round_index
    =
    let system_message : Bulkhead_lm.Openai_types.message =
      {
        role = "system";
        content = render_system_prompt participant;
      }
    in
    let user_message : Bulkhead_lm.Openai_types.message =
      {
        role = "user";
        content =
          Fmt.str
            "Participant: %s\nTask ID: %s\nMetadata: %s\nRound: %d/%d\n\nDiscussion topic:\n%s\n\nAgenda:\n%s\n\nTranscript so far:\n%s\n\nInstruction:\nAdd one compact contribution that moves the discussion forward. Build on the existing transcript when useful, avoid repeating earlier points, stay under %d words, and do not narrate the meta-process."
            participant.name
            context.task_id
            (render_metadata context.metadata)
            round_index
            discussion.max_rounds
            discussion.topic
            (render_agenda discussion.agenda)
            (render_transcript discussion.turns)
            max_contribution_words;
      }
    in
    [ system_message; user_message ]
end

let first_user_message (context : Core_context.t) =
  let rec loop = function
    | [] -> None
    | message :: rest ->
        (match message.Core_message.role with
         | Core_message.User -> Some message.content
         | System | Assistant | Agent _ | Speaker _ -> loop rest)
  in
  context.Core_context.history
  |> List.rev
  |> loop

let discussion_of_payload
    (config : Runtime_config.Discussion.t)
    (context : Core_context.t)
  = function
  | Core_payload.Plan agenda ->
      let topic =
        match first_user_message context with
        | Some message when String.trim message <> "" -> message
        | _ -> Core_payload.to_pretty_string (Core_payload.Plan agenda)
      in
      Ok
        {
          Core_payload.topic;
          agenda;
          turns = [];
          sub_discussions = [];
          completed_rounds = 0;
          max_rounds = config.rounds;
        }
  | Core_payload.Discussion discussion -> Ok discussion
  | payload ->
      Error
        (Fmt.str
           "Discussion workflow cannot process %s"
           (Core_payload.summary payload))

let participant_metrics
    (profile : Runtime_config.Llm.Agent_profile.t)
    (completion : Llm_bulkhead_client.completion)
  =
  {
    Core_payload.confidence = profile.confidence;
    cost = 0.0;
    latency_ms = 0;
  },
  [
    Fmt.str
      "Discussion participant route_model=%s resolved_model=%s prompt_tokens=%d completion_tokens=%d total_tokens=%d."
      completion.route_model
      completion.model
      completion.usage.prompt_tokens
      completion.usage.completion_tokens
      completion.usage.total_tokens;
    "Discussion provider access: "
    ^ Llm_bulkhead_client.route_access_summary completion.route_access;
  ]

(* Turn results are tri-state: a successful contribution, a skipped empty response,
   or a fatal budget-exhaustion that must halt the entire discussion immediately. *)
type turn_result =
  | Turn_produced of Core_payload.discussion_turn
  | Turn_skipped
  | Turn_budget_exhausted of string

let is_budget_exhausted message =
  let prefix = "budget_exceeded" in
  let plen = String.length prefix in
  String.length message >= plen
  && String.sub message 0 plen = prefix

let invoke_participant
    ~(services : Runtime_services.t)
    ~(context : Core_context.t)
    ~(discussion : Core_payload.discussion)
    ~(participant : Runtime_config.Discussion.Participant.t)
    ~round_index
  =
  let profile = participant.profile in
  let* result =
    Llm_bulkhead_client.invoke_messages
      services.llm_client
      ~route_model:profile.route_model
      ~messages:
        (Prompt_templates.build_messages
           ~participant
           ~context
           ~discussion
           ~round_index)
      ~max_tokens:profile.max_tokens
  in
  match result with
  | Error message when is_budget_exhausted message ->
      Runtime_logger.log
        Runtime_logger.Error
        (Live_output.turn_failed_message
           ~round_index
           ~max_rounds:discussion.max_rounds
           ~speaker:participant.name
           ~error:message);
      let context =
        Core_context.record_event
          context
          ~label:Event_label.turn_failed
          ~detail:
            (Fmt.str
               "round=%d speaker=%s error=%s"
               round_index
               participant.name
               message)
      in
      Lwt.return (Turn_budget_exhausted message, context)
  | Error message ->
      Runtime_logger.log
        Runtime_logger.Warning
        (Live_output.turn_failed_message
           ~round_index
           ~max_rounds:discussion.max_rounds
           ~speaker:participant.name
           ~error:message);
      let context =
        Core_context.record_event
          context
          ~label:Event_label.turn_failed
          ~detail:
            (Fmt.str
               "round=%d speaker=%s error=%s"
               round_index
               participant.name
               message)
      in
      Lwt.return (Turn_skipped, context)
  | Ok completion ->
      let content = String.trim completion.content in
      if content = ""
      then
        let route_access = completion.route_access in
        let () =
          Runtime_logger.log
            Runtime_logger.Warning
            (Live_output.turn_skipped_message
               ~round_index
               ~max_rounds:discussion.max_rounds
               ~speaker:participant.name
               ~route_model:route_access.route_model
               ~ready_backends:route_access.ready_backend_count)
        in
        let context =
          Core_context.record_event
            context
            ~label:Event_label.turn_skipped
            ~detail:
              (Fmt.str
                 "round=%d speaker=%s reason=empty_completion"
                 round_index
                 participant.name)
        in
        Lwt.return (Turn_skipped, context)
      else
        let metrics, notes = participant_metrics profile completion in
        let turn =
          {
            Core_payload.speaker = participant.name;
            round_index;
            content;
            metrics;
            notes;
          }
        in
        let context =
          Core_context.record_discussion_turn context turn
        in
        Runtime_logger.log
          Runtime_logger.Info
          (Live_output.turn_completed_message
             ~max_rounds:discussion.max_rounds
             turn);
        Lwt.return (Turn_produced turn, context)

let sub_discussion_marker = "[SUB_DISCUSSION:"

let extract_sub_topic content =
  let open_marker = sub_discussion_marker in
  let rec scan pos =
      if pos >= String.length content then None
      else
        let remaining = String.sub content pos (String.length content - pos) in
        let marker_len = String.length open_marker in
        if String.length remaining >= marker_len
           && String.sub remaining 0 marker_len = open_marker
        then
          let after_marker = String.sub remaining marker_len (String.length remaining - marker_len) in
          (match String.index_opt after_marker ']' with
           | Some close_pos ->
             let topic = String.trim (String.sub after_marker 0 close_pos) in
             if topic = "" then None else Some topic
           | None -> None)
        else scan (pos + 1)
    in
    scan 0

let rec run_round
    ~(services : Runtime_services.t)
    ~(config : Runtime_config.t)
    ~(participants : Runtime_config.Discussion.Participant.t list)
    ~(round_index : int)
    context
    (discussion : Core_payload.discussion)
  =
  let rec loop context (discussion : Core_payload.discussion) produced_turn_count =
    function
    | [] -> Lwt.return (`Ok, discussion, context, produced_turn_count)
    | participant :: rest ->
        let* turn_result, context =
          invoke_participant
            ~services
            ~context
            ~discussion
            ~participant
            ~round_index
        in
        (match turn_result with
         | Turn_budget_exhausted message ->
             Lwt.return (`Budget_exhausted message, discussion, context, produced_turn_count)
         | Turn_skipped ->
             loop context discussion produced_turn_count rest
         | Turn_produced turn ->
             let discussion =
               { discussion with turns = discussion.turns @ [ turn ] }
             in
             (* Detect sub-discussion requests *)
             let* discussion =
               if config.discussion.max_nesting_depth <= context.Core_context.nesting_depth
               then Lwt.return discussion
               else
                 match extract_sub_topic turn.content with
                 | None -> Lwt.return discussion
                 | Some sub_topic ->
                   Runtime_logger.log
                     Runtime_logger.Info
                     (Fmt.str "Spawning sub-discussion: %s (requested by %s)" sub_topic turn.speaker);
                   let child_task_id =
                     Fmt.str "%s/sub-%d-%s" context.task_id round_index turn.speaker
                   in
                   let child_context =
                     Core_context.child_context context ~child_task_id
                   in
                   let sub_plan = Core_payload.Plan [ sub_topic ] in
                   let* sub_payload, _sub_context =
                     run_sub
                       ~services
                       ~config
                       child_context
                       sub_plan
                   in
                   let sub_disc =
                     match sub_payload with
                     | Core_payload.Discussion d -> d
                     | _ ->
                       { Core_payload.topic = sub_topic
                       ; agenda = [ sub_topic ]
                       ; turns = []
                       ; sub_discussions = []
                       ; completed_rounds = 0
                       ; max_rounds = 0
                       }
                   in
                   let sub_entry =
                     { Core_payload.sub_topic
                     ; spawned_by = turn.speaker
                     ; spawned_at_round = round_index
                     ; discussion = sub_disc
                     }
                   in
                   Lwt.return
                     { discussion with
                       sub_discussions = discussion.sub_discussions @ [ sub_entry ]
                     }
             in
             loop context discussion (produced_turn_count + 1) rest)
  in
  loop context discussion 0 participants

and run_sub ~services ~config context payload =
  (* Recursive sub-discussion with the same participants but a nested context *)
  match discussion_of_payload config.Runtime_config.discussion context payload with
  | Error message -> Lwt.return (Core_payload.Error message, context)
  | Ok discussion when not config.discussion.enabled ->
    Lwt.return (Core_payload.Discussion discussion, context)
  | Ok discussion ->
    let rec sub_loop context (discussion : Core_payload.discussion) round_index =
      if round_index > discussion.max_rounds
      then Lwt.return (Core_payload.Discussion discussion, context)
      else
        let* round_status, discussion, context, turn_count =
          run_round
            ~services
            ~config
            ~participants:config.discussion.participants
            ~round_index
            context
            discussion
        in
        let discussion = { discussion with completed_rounds = round_index } in
        let context =
          Core_context.record_discussion_round context ~round_index ~turn_count
        in
        match round_status with
        | `Budget_exhausted _ ->
          Lwt.return (Core_payload.Discussion discussion, context)
        | `Ok ->
          if turn_count = 0
          then Lwt.return (Core_payload.Discussion discussion, context)
          else sub_loop context discussion (round_index + 1)
    in
    sub_loop context discussion 1

let warn_unready_participant_routes
    (llm_client : Llm_bulkhead_client.t)
    (participants : Runtime_config.Discussion.Participant.t list)
  =
  participants
  |> List.iter (fun (participant : Runtime_config.Discussion.Participant.t) ->
         let route_model = participant.profile.route_model in
         match Llm_bulkhead_client.route_access llm_client ~route_model with
         | Some access when access.ready_backend_count = 0 ->
             Runtime_logger.log
               Runtime_logger.Warning
               (Live_output.unready_route_message
                  ~participant_name:participant.name
                  ~route_model)
         | _ -> ())

let run
    ~(services : Runtime_services.t)
    ~(config : Runtime_config.t)
    context
    payload
  =
  match discussion_of_payload config.discussion context payload with
  | Error message ->
      let context =
        Core_context.record_event
          context
          ~label:Event_label.failed
          ~detail:message
      in
      Lwt.return (Core_payload.Error message, context)
  | Ok discussion when not config.discussion.enabled ->
      Lwt.return (Core_payload.Discussion discussion, context)
  | Ok discussion ->
      let participant_names =
        config.discussion.participants
        |> List.map (fun (participant : Runtime_config.Discussion.Participant.t) ->
               participant.name)
        |> String.concat ", "
      in
      let context =
        Core_context.record_event
          context
          ~label:Event_label.started
          ~detail:
            (Fmt.str
               "rounds=%d final_agent=%s participants=%s"
               config.discussion.rounds
               (Core_agent_name.to_string config.discussion.final_agent)
               participant_names)
      in
      Runtime_logger.log
        Runtime_logger.Info
        (Live_output.started_message config.discussion);
      warn_unready_participant_routes
        services.llm_client
        config.discussion.participants;
      let rec loop context (discussion : Core_payload.discussion) round_index =
        if round_index > discussion.max_rounds
        then Lwt.return (Core_payload.Discussion discussion, context)
        else
          let () =
            Runtime_logger.log
              Runtime_logger.Info
              (Live_output.round_started_message
                 ~round_index
                 ~max_rounds:discussion.max_rounds
                 ~participants:config.discussion.participants)
          in
          let context =
            Core_context.record_event
              context
              ~label:Event_label.round_started
              ~detail:(Fmt.str "round=%d" round_index)
          in
          let* round_status, discussion, context, turn_count =
            run_round
              ~services
              ~config
              ~participants:config.discussion.participants
              ~round_index
              context
              discussion
          in
          let discussion =
            { discussion with completed_rounds = round_index }
          in
          let context =
            Core_context.record_discussion_round
              context
              ~round_index
              ~turn_count
          in
          Runtime_logger.log
            Runtime_logger.Info
            (Live_output.round_completed_message
               ~round_index
               ~max_rounds:discussion.max_rounds
               ~turn_count);
          (match round_status with
           | `Budget_exhausted message ->
               Runtime_logger.log
                 Runtime_logger.Warning
                 (Live_output.budget_exhausted_message
                    ~collected_turns:(List.length discussion.turns)
                    ~message);
               Lwt.return (Core_payload.Discussion discussion, context)
           | `Ok ->
               if turn_count = 0
               then
                 if discussion.turns = []
                 then
                   let message =
                     "Discussion workflow produced no participant contribution."
                   in
                   Runtime_logger.log Runtime_logger.Warning message;
                   let context =
                     Core_context.record_event
                       context
                       ~label:Event_label.failed
                       ~detail:message
                   in
                   Lwt.return (Core_payload.Error message, context)
                 else Lwt.return (Core_payload.Discussion discussion, context)
               else loop context discussion (round_index + 1))
      in
      loop context discussion (discussion.completed_rounds + 1)
