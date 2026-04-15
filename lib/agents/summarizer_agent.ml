open Lwt.Infix

module Defaults = struct
  let summary_word_budget = 18
  let discussion_summary_word_budget = 140
end

let id = Core_agent_name.Summarizer
let discussion_converged_marker = "[DISCUSSION_CONVERGED]"

let normalize_words text =
  text
  |> String.split_on_char ' '
  |> List.filter (fun word -> String.trim word <> "")

let take count items =
  let rec aux remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | item :: rest -> aux (remaining - 1) (item :: acc) rest
  in
  aux count [] items

let summarize_text text =
  let words = normalize_words text in
  let excerpt =
    words
    |> take Defaults.summary_word_budget
    |> String.concat " "
  in
  if List.length words > Defaults.summary_word_budget then excerpt ^ " ..."
  else excerpt

let summarize_plan steps =
  steps
  |> List.mapi (fun index step -> Fmt.str "%d) %s" (index + 1) step)
  |> String.concat " | "

let strip_convergence_marker text =
  let trimmed = String.trim text in
  let marker_length = String.length discussion_converged_marker in
  if String.length trimmed >= marker_length
     && String.sub trimmed 0 marker_length = discussion_converged_marker
  then
    String.sub trimmed marker_length (String.length trimmed - marker_length)
    |> String.trim
  else trimmed

let meta_summary_markers =
  [ "we are given"
  ; "the payload"
  ; "the transcript"
  ; "the task is"
  ; "round 1"
  ; "round 2"
  ; "word count"
  ; "the user asked"
  ; "history of the conversation"
  ]

let contains_substring ~substring value =
  let substring_length = String.length substring in
  let value_length = String.length value in
  let rec loop index =
    if index + substring_length > value_length then false
    else if String.sub value index substring_length = substring then true
    else loop (index + 1)
  in
  if substring_length = 0 then true else loop 0

let looks_like_meta_summary text =
  let lowered = String.lowercase_ascii text in
  List.exists (fun marker -> contains_substring ~substring:marker lowered) meta_summary_markers

let sanitized_discussion (discussion : Core_payload.discussion) =
  let sanitize_turn (turn : Core_payload.discussion_turn) =
    { turn with content = strip_convergence_marker turn.content }
  in
  { discussion with turns = List.map sanitize_turn discussion.turns }

let discussion_llm_instruction (discussion : Core_payload.discussion) =
  let discussion =
    sanitized_discussion discussion
  in
  Fmt.str
    "You are the final synthesizer for a structured discussion.\nAnswer the discussion topic directly using the agenda and transcript below.\nDo not mention the payload, transcript, rounds, participants, or internal workflow unless strictly necessary.\nIf the discussion is inconclusive, say what remains uncertain and what must be verified next.\nKeep the answer under %d words. No headings.\n\n%s"
    Defaults.discussion_summary_word_budget
    (Core_payload.to_pretty_string (Core_payload.Discussion discussion))

let summarize_discussion (discussion : Core_payload.discussion) =
  let discussion =
    sanitized_discussion discussion
  in
  let agenda_summary =
    match discussion.agenda with
    | [] -> "no explicit agenda"
    | steps -> summarize_plan steps
  in
  let preferred_conclusion =
    let last_turn_by_speaker speaker =
      discussion.turns
      |> List.rev
      |> List.find_map (fun (turn : Core_payload.discussion_turn) ->
             if String.equal turn.speaker speaker
             then Some (String.trim turn.content)
             else None)
    in
    match
      last_turn_by_speaker "implementer",
      last_turn_by_speaker "architect",
      last_turn_by_speaker "critic"
    with
    | Some text, _, _ when text <> "" -> Some text
    | _, Some text, _ when text <> "" -> Some text
    | _, _, Some text when text <> "" -> Some text
    | _ ->
        discussion.turns
        |> List.rev
        |> List.find_map (fun (turn : Core_payload.discussion_turn) ->
               let text = String.trim turn.content in
               if text = "" then None else Some text)
  in
  match preferred_conclusion with
  | Some text -> summarize_text text
  | None -> Fmt.str "Discussion topic: %s. Agenda: %s." discussion.topic agenda_summary

let llm_instruction payload =
  Fmt.str
    "Write a concise summary of the payload below.\nUse plain English.\nKeep the answer under 80 words.\nDo not add headings.\n\nPayload:\n%s"
    (Core_payload.to_pretty_string payload)

let route_access_note services profile =
  match
    Llm_bulkhead_client.route_access
      services.Runtime_services.llm_client
      ~route_model:profile.Runtime_config.Llm.Agent_profile.route_model
  with
  | Some route_access ->
      "Summarizer provider access: "
      ^ Llm_bulkhead_client.route_access_summary route_access
  | None ->
      Fmt.str
        "Summarizer provider access: route_model=%s is missing from the loaded BulkheadLM config."
        profile.route_model

let llm_metrics profile completion =
  {
    Core_payload.confidence = profile.Runtime_config.Llm.Agent_profile.confidence;
    cost = 0.0;
    latency_ms = 0;
  },
  [
    Fmt.str
      "Summarizer used route_model=%s resolved_model=%s prompt_tokens=%d completion_tokens=%d total_tokens=%d."
      completion.Llm_bulkhead_client.route_model
      completion.model
      completion.usage.prompt_tokens
      completion.usage.completion_tokens
      completion.usage.total_tokens;
    "Summarizer provider access: "
    ^ Llm_bulkhead_client.route_access_summary completion.route_access;
  ]

let run services context = function
  | Core_payload.Text text ->
      let payload = Core_payload.Text text in
      let profile =
        services.Runtime_services.config.Runtime_config.llm.summarizer
      in
      Llm_bulkhead_client.invoke_chat
        services.llm_client
        ~agent:id
        ~profile
        ~context
        ~payload
        ~instruction:(llm_instruction payload)
      >|= (function
       | Ok completion ->
           let summary =
             match String.trim completion.content with
             | "" -> summarize_text text
             | content -> content
           in
           let metrics, notes = llm_metrics profile completion in
           Core_payload.Text ("Summary: " ^ summary), metrics, notes
       | Error message ->
           ( Core_payload.Error ("Summarizer LLM call failed: " ^ message),
             Core_payload.zero_metrics,
             [
               "Summarizer failed to obtain a response from BulkheadLM.";
               route_access_note services profile;
             ] ))
  | Core_payload.Plan steps ->
      let payload = Core_payload.Plan steps in
      let profile =
        services.Runtime_services.config.Runtime_config.llm.summarizer
      in
      Llm_bulkhead_client.invoke_chat
        services.llm_client
        ~agent:id
        ~profile
        ~context
        ~payload
        ~instruction:(llm_instruction payload)
      >|= (function
       | Ok completion ->
           let summary =
             match String.trim completion.content with
             | "" -> summarize_plan steps
             | content -> content
           in
           let metrics, notes = llm_metrics profile completion in
           Core_payload.Text ("Summary: " ^ summary), metrics, notes
       | Error message ->
           ( Core_payload.Error ("Summarizer LLM call failed: " ^ message),
             Core_payload.zero_metrics,
             [
               "Summarizer failed to obtain a response from BulkheadLM.";
               route_access_note services profile;
             ] ))
  | Core_payload.Discussion discussion ->
      let payload = Core_payload.Discussion discussion in
      let profile =
        services.Runtime_services.config.Runtime_config.llm.summarizer
      in
      Llm_bulkhead_client.invoke_chat
        services.llm_client
        ~agent:id
        ~profile
        ~context
        ~payload
        ~instruction:(discussion_llm_instruction discussion)
      >|= (function
       | Ok completion ->
           let summary =
             match String.trim completion.content with
             | "" -> summarize_discussion discussion
             | content when looks_like_meta_summary content -> summarize_discussion discussion
             | content -> strip_convergence_marker content
           in
           let metrics, notes = llm_metrics profile completion in
           Core_payload.Text ("Summary: " ^ summary), metrics, notes
       | Error message ->
           ( Core_payload.Error ("Summarizer LLM call failed: " ^ message),
             Core_payload.zero_metrics,
             [
               "Summarizer failed to obtain a response from BulkheadLM.";
               route_access_note services profile;
             ] ))
  | payload ->
      let metrics = Core_payload.zero_metrics in
      Lwt.return
        ( Core_payload.Error
            (Fmt.str
               "Summarizer cannot process %s"
               (Core_payload.summary payload)),
          metrics,
          [ "Summarizer rejected an unsupported payload." ] )
