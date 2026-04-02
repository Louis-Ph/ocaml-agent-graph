open Lwt.Infix

module Defaults = struct
  let summary_word_budget = 18
end

let id = Core_agent_name.Summarizer

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

let llm_instruction payload =
  Fmt.str
    "Write a concise summary of the payload below.\nUse plain English.\nKeep the answer under 80 words.\nDo not add headings.\n\nPayload:\n%s"
    (Core_payload.to_pretty_string payload)

let llm_metrics profile completion =
  {
    Core_payload.confidence = profile.Runtime_config.Llm.Agent_profile.confidence;
    cost = 0.0;
    latency_ms = 0;
  },
  [
    Fmt.str
      "Summarizer used model=%s prompt_tokens=%d completion_tokens=%d total_tokens=%d."
      completion.Llm_aegis_client.model
      completion.usage.prompt_tokens
      completion.usage.completion_tokens
      completion.usage.total_tokens;
  ]

let run services context = function
  | Core_payload.Text text ->
      let payload = Core_payload.Text text in
      let profile =
        services.Runtime_services.config.Runtime_config.llm.summarizer
      in
      Llm_aegis_client.invoke_chat
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
             [ "Summarizer failed to obtain a response from AegisLM." ] ))
  | Core_payload.Plan steps ->
      let payload = Core_payload.Plan steps in
      let profile =
        services.Runtime_services.config.Runtime_config.llm.summarizer
      in
      Llm_aegis_client.invoke_chat
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
             [ "Summarizer failed to obtain a response from AegisLM." ] ))
  | payload ->
      let metrics = Core_payload.zero_metrics in
      Lwt.return
        ( Core_payload.Error
            (Fmt.str
               "Summarizer cannot process %s"
               (Core_payload.summary payload)),
          metrics,
          [ "Summarizer rejected an unsupported payload." ] )
