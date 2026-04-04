open Lwt.Infix

module Defaults = struct
  let max_steps = 5
end

let id = Core_agent_name.Planner

let is_separator = function
  | '.' | '!' | '?' | ';' | ':' | '\n' -> true
  | _ -> false

let extract_segments text =
  let buffer = Buffer.create (String.length text) in
  let segments = ref [] in
  let flush () =
    let segment = Buffer.contents buffer |> String.trim in
    Buffer.clear buffer;
    if segment <> "" then segments := segment :: !segments
  in
  String.iter
    (fun character ->
      if is_separator character then flush () else Buffer.add_char buffer character)
    text;
  flush ();
  List.rev !segments

let take count items =
  let rec aux remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | item :: rest -> aux (remaining - 1) (item :: acc) rest
  in
  aux count [] items

let fallback_plan =
  [
    "Clarify the objective and isolate the state transitions.";
    "Run the execution stage with explicit policies.";
    "Validate the output and collect auditable metrics.";
  ]

let strip_prefixes line =
  let trimmed = String.trim line in
  let rec drop_numeric_prefix index =
    if index >= String.length trimmed then trimmed
    else
      match trimmed.[index] with
      | '0' .. '9' | '.' | ')' | '-' | '*' | ' ' -> drop_numeric_prefix (index + 1)
      | _ -> String.sub trimmed index (String.length trimmed - index)
  in
  drop_numeric_prefix 0 |> String.trim

let normalize_plan_lines text =
  text
  |> String.split_on_char '\n'
  |> List.map strip_prefixes
  |> List.filter (fun line -> line <> "")
  |> take Defaults.max_steps

let plan_from_lines lines =
  match lines with
  | [] -> fallback_plan
  | _ ->
      lines
      |> List.mapi (fun index line ->
             if String.starts_with ~prefix:"Stage " line then line
             else Fmt.str "Stage %d: %s" (index + 1) line)

let plan_from_text text =
  let steps =
    extract_segments text
    |> take Defaults.max_steps
    |> List.mapi (fun index segment ->
           Fmt.str "Stage %d: %s" (index + 1) segment)
  in
  match steps with
  | [] -> fallback_plan
  | _ -> steps

let llm_instruction text =
  Fmt.str
    "Turn the request below into a compact execution plan.\nReturn 2 to 5 short lines.\nEach line must describe one action.\nDo not add commentary before or after the lines.\n\nRequest:\n%s"
    text

let route_access_note services profile =
  match
    Llm_aegis_client.route_access
      services.Runtime_services.llm_client
      ~route_model:profile.Runtime_config.Llm.Agent_profile.route_model
  with
  | Some route_access ->
      "Planner provider access: "
      ^ Llm_aegis_client.route_access_summary route_access
  | None ->
      Fmt.str
        "Planner provider access: route_model=%s is missing from the loaded AegisLM config."
        profile.route_model

let llm_metrics profile completion =
  {
    Core_payload.confidence = profile.Runtime_config.Llm.Agent_profile.confidence;
    cost = 0.0;
    latency_ms = 0;
  },
  [
    Fmt.str
      "Planner used route_model=%s resolved_model=%s prompt_tokens=%d completion_tokens=%d total_tokens=%d."
      completion.Llm_aegis_client.route_model
      completion.model
      completion.usage.prompt_tokens
      completion.usage.completion_tokens
      completion.usage.total_tokens;
    "Planner provider access: "
    ^ Llm_aegis_client.route_access_summary completion.route_access;
  ]

let run services _context = function
  | Core_payload.Text text ->
      let profile =
        services.Runtime_services.config.Runtime_config.llm.planner
      in
      Llm_aegis_client.invoke_chat
        services.llm_client
        ~agent:id
        ~profile
        ~context:_context
        ~payload:(Core_payload.Text text)
        ~instruction:(llm_instruction text)
      >|= (function
       | Ok completion ->
           let lines = normalize_plan_lines completion.content in
           let plan =
             match lines with
             | [] -> plan_from_text text
             | _ -> plan_from_lines lines
           in
           let metrics, notes = llm_metrics profile completion in
           Core_payload.Plan plan, metrics, notes
       | Error message ->
           ( Core_payload.Error ("Planner LLM call failed: " ^ message),
             Core_payload.zero_metrics,
             [
               "Planner failed to obtain a response from AegisLM.";
               route_access_note services profile;
             ] ))
  | payload ->
      let metrics = Core_payload.zero_metrics in
      Lwt.return
        ( Core_payload.Error
            (Fmt.str "Planner cannot process %s" (Core_payload.summary payload)),
          metrics,
          [ "Planner rejected a non-text payload." ] )
