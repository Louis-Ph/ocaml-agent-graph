open Lwt.Syntax

module Prompt_templates = struct
  let max_contribution_words = 120

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
    let profile = participant.profile in
    let system_message : Bulkhead_lm.Openai_types.message =
      {
        role = "system";
        content = profile.Runtime_config.Llm.Agent_profile.system_prompt;
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
  | Error message ->
      let context =
        Core_context.record_event
          context
          ~label:"discussion.turn.failed"
          ~detail:
            (Fmt.str
               "round=%d speaker=%s error=%s"
               round_index
               participant.name
               message)
      in
      Lwt.return (None, context)
  | Ok completion ->
      let content = String.trim completion.content in
      if content = ""
      then
        let context =
          Core_context.record_event
            context
            ~label:"discussion.turn.skipped"
            ~detail:
              (Fmt.str
                 "round=%d speaker=%s reason=empty_completion"
                 round_index
                 participant.name)
        in
        Lwt.return (None, context)
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
        Lwt.return (Some turn, context)

let run_round
    ~(services : Runtime_services.t)
    ~(participants : Runtime_config.Discussion.Participant.t list)
    ~(round_index : int)
    context
    (discussion : Core_payload.discussion)
  =
  let rec loop context (discussion : Core_payload.discussion) produced_turn_count =
    function
    | [] -> Lwt.return (discussion, context, produced_turn_count)
    | participant :: rest ->
        let* maybe_turn, context =
          invoke_participant
            ~services
            ~context
            ~discussion
            ~participant
            ~round_index
        in
        let discussion, produced_turn_count =
          match maybe_turn with
          | None -> discussion, produced_turn_count
          | Some turn ->
              ( { discussion with turns = discussion.turns @ [ turn ] },
                produced_turn_count + 1 )
        in
        loop context discussion produced_turn_count rest
  in
  loop context discussion 0 participants

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
          ~label:"discussion.failed"
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
          ~label:"discussion.started"
          ~detail:
            (Fmt.str
               "rounds=%d final_agent=%s participants=%s"
               config.discussion.rounds
               (Core_agent_name.to_string config.discussion.final_agent)
               participant_names)
      in
      let rec loop context (discussion : Core_payload.discussion) round_index =
        if round_index > discussion.max_rounds
        then Lwt.return (Core_payload.Discussion discussion, context)
        else
          let context =
            Core_context.record_event
              context
              ~label:"discussion.round.started"
              ~detail:(Fmt.str "round=%d" round_index)
          in
          let* discussion, context, turn_count =
            run_round
              ~services
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
          if turn_count = 0
          then
            if discussion.turns = []
            then
              let message =
                "Discussion workflow produced no participant contribution."
              in
              let context =
                Core_context.record_event
                  context
                  ~label:"discussion.failed"
                  ~detail:message
              in
              Lwt.return (Core_payload.Error message, context)
            else Lwt.return (Core_payload.Discussion discussion, context)
          else loop context discussion (round_index + 1)
      in
      loop context discussion (discussion.completed_rounds + 1)
