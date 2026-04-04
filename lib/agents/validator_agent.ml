open Lwt.Infix

module Defaults = struct
  let fallback_text_limit = 512
end

let id = Core_agent_name.Validator

let bool_to_status = function
  | true -> "OK"
  | false -> "WARN"

let validate_text text =
  let length = String.length text in
  [
    ("non_empty", length > 0);
    ("sufficient_context", length >= 32);
    ("bounded_size", length <= Defaults.fallback_text_limit);
  ]
  |> List.map (fun (label, status) ->
         Fmt.str "%s:%s" label (bool_to_status status))
  |> String.concat " | "

let validate_plan steps =
  let enough_steps = List.length steps >= 2 in
  let labelled_steps =
    List.for_all
      (fun step -> String.length (String.trim step) >= 8)
      steps
  in
  let unique_steps =
    let sorted = List.sort String.compare steps in
    let deduplicated =
      List.sort_uniq String.compare sorted
    in
    List.length sorted = List.length deduplicated
  in
  [
    ("enough_steps", enough_steps);
    ("labelled_steps", labelled_steps);
    ("unique_steps", unique_steps);
  ]
  |> List.map (fun (label, status) ->
         Fmt.str "%s:%s" label (bool_to_status status))
  |> String.concat " | "

let llm_instruction payload =
  Fmt.str
    "Validate the payload below.\nReturn one compact line with a verdict, the main strengths, and the main risks.\nDo not use markdown bullets.\n\nPayload:\n%s"
    (Core_payload.to_pretty_string payload)

let route_access_note services profile =
  match
    Llm_aegis_client.route_access
      services.Runtime_services.llm_client
      ~route_model:profile.Runtime_config.Llm.Agent_profile.route_model
  with
  | Some route_access ->
      "Validator provider access: "
      ^ Llm_aegis_client.route_access_summary route_access
  | None ->
      Fmt.str
        "Validator provider access: route_model=%s is missing from the loaded AegisLM config."
        profile.route_model

let llm_metrics profile completion =
  {
    Core_payload.confidence = profile.Runtime_config.Llm.Agent_profile.confidence;
    cost = 0.0;
    latency_ms = 0;
  },
  [
    Fmt.str
      "Validator used route_model=%s resolved_model=%s prompt_tokens=%d completion_tokens=%d total_tokens=%d."
      completion.Llm_aegis_client.route_model
      completion.model
      completion.usage.prompt_tokens
      completion.usage.completion_tokens
      completion.usage.total_tokens;
    "Validator provider access: "
    ^ Llm_aegis_client.route_access_summary completion.route_access;
  ]

let run services context = function
  | Core_payload.Text text ->
      let payload = Core_payload.Text text in
      let profile =
        services.Runtime_services.config.Runtime_config.llm.validator
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
             | "" -> validate_text text
             | content -> content
           in
           let metrics, notes = llm_metrics profile completion in
           Core_payload.Text ("Validation: " ^ summary), metrics, notes
       | Error message ->
           ( Core_payload.Error ("Validator LLM call failed: " ^ message),
             Core_payload.zero_metrics,
             [
               "Validator failed to obtain a response from AegisLM.";
               route_access_note services profile;
             ] ))
  | Core_payload.Plan steps ->
      let payload = Core_payload.Plan steps in
      let profile =
        services.Runtime_services.config.Runtime_config.llm.validator
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
             | "" -> validate_plan steps
             | content -> content
           in
           let metrics, notes = llm_metrics profile completion in
           Core_payload.Text ("Validation: " ^ summary), metrics, notes
       | Error message ->
           ( Core_payload.Error ("Validator LLM call failed: " ^ message),
             Core_payload.zero_metrics,
             [
               "Validator failed to obtain a response from AegisLM.";
               route_access_note services profile;
             ] ))
  | payload ->
      let metrics = Core_payload.zero_metrics in
      Lwt.return
        ( Core_payload.Error
            (Fmt.str
               "Validator cannot process %s"
               (Core_payload.summary payload)),
          metrics,
          [ "Validator rejected an unsupported payload." ] )
