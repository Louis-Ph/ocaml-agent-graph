type picked_participant = { name : string; focus : string; why : string option }
type result = { runtime : Client_runtime.t; lines : string list }

let max_focus_words = 32
let fallback_focus = "Drive the exchange toward a concrete, actionable result."

let trim_conversation (runtime : Client_runtime.t) conversation =
  let keep =
    runtime.Client_runtime.client_config.human_terminal.conversation_keep_turns
    * 2
  in
  let rec drop count items =
    if List.length items <= count then items else drop count (List.tl items)
  in
  if keep <= 0 then [] else drop keep conversation

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let non_empty_string = function
  | `String value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let unwrap_markdown_code_block content =
  let trimmed = String.trim content in
  if not (String.starts_with ~prefix:"```" trimmed) then None
  else
    match String.index_opt trimmed '\n' with
    | None -> None
    | Some first_newline ->
        let remainder =
          String.sub trimmed (first_newline + 1)
            (String.length trimmed - first_newline - 1)
          |> String.trim
        in
        if String.ends_with ~suffix:"```" remainder then
          Some
            (String.sub remainder 0 (String.length remainder - 3) |> String.trim)
        else None

let parse_json content =
  let trimmed = String.trim content in
  let parse value = try Some (Yojson.Safe.from_string value) with _ -> None in
  match parse trimmed with
  | Some json -> Some json
  | None -> (
      match unwrap_markdown_code_block trimmed with
      | Some unfenced -> parse unfenced
      | None -> None)

let normalize_words ~max_words text =
  let words =
    text |> String.split_on_char ' ' |> List.map String.trim
    |> List.filter (fun word -> word <> "")
  in
  let rec take remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | word :: rest -> take (remaining - 1) (word :: acc) rest
  in
  match take max_words [] words with
  | [] -> fallback_focus
  | limited -> String.concat " " limited

let normalize_focus text =
  let text = String.trim text in
  if text = "" then fallback_focus
  else normalize_words ~max_words:max_focus_words text

let picked_participant_of_yojson json =
  let name =
    match member "name" json with
    | Some value -> non_empty_string value
    | None -> (
        match member "participant" json with
        | Some value -> non_empty_string value
        | None -> (
            match member "template_name" json with
            | Some value -> non_empty_string value
            | None -> None))
  in
  let focus =
    match member "focus" json with
    | Some value -> non_empty_string value
    | None -> (
        match member "mission" json with
        | Some value -> non_empty_string value
        | None -> (
            match member "brief" json with
            | Some value -> non_empty_string value
            | None -> None))
  in
  match name with
  | None -> None
  | Some name ->
      Some
        {
          name;
          focus = normalize_focus (Option.value focus ~default:fallback_focus);
          why =
            (match member "why" json with
            | Some value -> non_empty_string value
            | None -> None);
        }

let parse_picks content =
  match parse_json content with
  | Some (`Assoc _ as json) -> (
      match member "participants" json with
      | Some (`List values) ->
          List.filter_map picked_participant_of_yojson values
      | _ -> [])
  | Some (`List values) -> List.filter_map picked_participant_of_yojson values
  | _ -> []

let normalize_name_key value = value |> String.trim |> String.lowercase_ascii

let contains_substring ~substring value =
  let substring_length = String.length substring in
  let value_length = String.length value in
  let rec loop index =
    if index + substring_length > value_length then false
    else if String.sub value index substring_length = substring then true
    else loop (index + 1)
  in
  if substring_length = 0 then true else loop 0

let default_focus_for_name name =
  let lowered = normalize_name_key name in
  if String.starts_with ~prefix:"architect" lowered then
    "Define the strongest structure, hierarchy, and module boundaries."
  else if String.starts_with ~prefix:"critic" lowered then
    "Stress-test assumptions, risks, evidence gaps, and weak tradeoffs."
  else if String.starts_with ~prefix:"implementer" lowered then
    "Propose the smallest concrete implementation slice and the matching tests."
  else if String.starts_with ~prefix:"validator" lowered then
    "Verify correctness, force clarity, and name the minimum proof needed."
  else fallback_focus

let heuristic_picks_from_text
    (participants : Runtime_config.Discussion.Participant.t list) content =
  let lowered = String.lowercase_ascii content in
  participants
  |> List.filter_map
       (fun (participant : Runtime_config.Discussion.Participant.t) ->
         let name_key = normalize_name_key participant.name in
         if name_key <> "" && contains_substring ~substring:name_key lowered
         then
           Some
             {
               name = participant.name;
               focus = default_focus_for_name participant.name;
               why = Some "Recovered from a non-JSON team builder reply.";
             }
         else None)

let find_participant_by_name participants target_name =
  let target_key = normalize_name_key target_name in
  participants
  |> List.find_opt
       (fun (participant : Runtime_config.Discussion.Participant.t) ->
         normalize_name_key participant.name = target_key)

let inject_focus (participant : Runtime_config.Discussion.Participant.t) focus =
  let profile = participant.profile in
  let system_prompt =
    Fmt.str
      "%s\n\n\
       Discussion-specific focus for this run:\n\
       - %s\n\
       - Push toward a concrete outcome, decision, or implementation slice.\n\
       - Keep every reply under 380 words."
      (String.trim profile.system_prompt)
      focus
  in
  { participant with profile = { profile with system_prompt } }

let apply_picks (participants : Runtime_config.Discussion.Participant.t list)
    picks =
  let rec loop seen applied = function
    | [] -> List.rev applied
    | pick :: rest -> (
        let key = normalize_name_key pick.name in
        if List.mem key seen then loop seen applied rest
        else
          match find_participant_by_name participants pick.name with
          | None -> loop seen applied rest
          | Some participant ->
              loop (key :: seen)
                ((inject_focus participant pick.focus, pick) :: applied)
                rest)
  in
  loop [] [] picks

let attachment_prompt attachments =
  match attachments with
  | [] -> "none"
  | _ ->
      attachments
      |> List.map Client_assistant.render_attachment
      |> String.concat "\n\n"

let conversation_prompt conversation =
  match conversation with
  | [] -> "none"
  | _ ->
      conversation |> List.rev
      |> List.rev_map (fun (message : Bulkhead_lm.Openai_types.message) ->
             Fmt.str "%s: %s" message.role (String.trim message.content))
      |> String.concat "\n"

let participant_catalog_prompt
    (participants : Runtime_config.Discussion.Participant.t list) =
  participants
  |> List.map (fun (participant : Runtime_config.Discussion.Participant.t) ->
         let profile = participant.profile in
         Fmt.str "- name=%s route_model=%s max_tokens=%s confidence=%.2f"
           participant.name profile.route_model
           (match profile.max_tokens with
           | Some value -> string_of_int value
           | None -> "none")
           profile.confidence)
  |> String.concat "\n"

let build_messages runtime ~active_route_model ~conversation ~prompt_text
    ~attachments ~participants =
  let system_message : Bulkhead_lm.Openai_types.message =
    {
      role = "system";
      content =
        "You are the discussion team builder.\n\
         Goal: choose the best likely discussion team for a concrete result.\n\
         You MUST choose 2 to 4 participants from the available templates only.\n\
         Use the exact existing participant names.\n\
         Assign each selected participant one short focus sentence.\n\
         Prefer teams that improve execution quality: architecture, critique, \
         implementation, verification, delivery.\n\
         Return JSON only in this exact shape:\n\
         {\"participants\":[{\"name\":\"existing-name\",\"focus\":\"short \
         concrete mission\",\"why\":\"optional short reason\"}]}\n\
         Do not invent names. Do not add commentary outside JSON.";
    }
  in
  let user_message : Bulkhead_lm.Openai_types.message =
    {
      role = "user";
      content =
        Fmt.str
          "Current main route_model:\n\
           %s\n\n\
           Current discussion request:\n\
           %s\n\n\
           Current assistant conversation:\n\
           %s\n\n\
           Attached files:\n\
           %s\n\n\
           Available participant templates:\n\
           %s"
          active_route_model prompt_text
          (conversation_prompt (trim_conversation runtime conversation))
          (attachment_prompt attachments)
          (participant_catalog_prompt participants);
    }
  in
  [ system_message; user_message ]

let fallback_result runtime ~route_model ~reason =
  {
    runtime;
    lines =
      [
        Fmt.str "team_builder_route_model: %s" route_model;
        Fmt.str "fallback: %s" reason;
      ]
      @ (runtime.runtime_config.discussion.participants
        |> List.map
             (fun (participant : Runtime_config.Discussion.Participant.t) ->
               Fmt.str "- %s: %s" participant.name fallback_focus));
  }

let selected_runtime (runtime : Client_runtime.t) participants =
  let runtime_config =
    {
      runtime.Client_runtime.runtime_config with
      discussion = { runtime.runtime_config.discussion with participants };
    }
  in
  Client_runtime.of_parts ~client_config_path:runtime.client_config_path
    ~client_config:runtime.client_config
    ~runtime_config_path:runtime.runtime_config_path ~runtime_config
    ~llm_client:runtime.llm_client

let build (runtime : Client_runtime.t) ~active_route_model ~conversation
    ~prompt_text ~attachments =
  let participants = runtime.runtime_config.discussion.participants in
  let route_model = active_route_model in
  if List.length participants < 2 then
    fallback_result runtime ~route_model
      ~reason:"discussion config has fewer than 2 participant templates"
  else
    match
      Lwt_main.run
        (Llm_bulkhead_client.invoke_messages runtime.llm_client ~route_model
           ~messages:
             (build_messages runtime ~active_route_model ~conversation
                ~prompt_text ~attachments ~participants)
           ~max_tokens:(Some 320))
    with
    | Error message ->
        fallback_result runtime ~route_model
          ~reason:(Fmt.str "team builder unavailable: %s" message)
    | Ok completion ->
        let picks =
          match parse_picks completion.content with
          | [] -> heuristic_picks_from_text participants completion.content
          | picks -> picks
        in
        let applied = apply_picks participants picks in
        if List.length applied < 2 then
          fallback_result runtime ~route_model
            ~reason:
              "team builder response was invalid or selected fewer than 2 \
               valid participants"
        else
          let selected_participants = applied |> List.map fst in
          let lines =
            [
              Fmt.str "team_builder_route_model: %s" route_model;
              Fmt.str "resolved_model: %s" completion.model;
              Fmt.str "selected_participants: %d" (List.length applied);
            ]
            @ (applied
              |> List.map
                   (fun
                     ( (participant : Runtime_config.Discussion.Participant.t),
                       pick )
                   ->
                     match pick.why with
                     | Some why ->
                         Fmt.str "- %s: %s (why: %s)" participant.name
                           pick.focus why
                     | None -> Fmt.str "- %s: %s" participant.name pick.focus))
          in
          { runtime = selected_runtime runtime selected_participants; lines }
