module Defaults = struct
  let confidence = 0.94
  let cost = 0.0028
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
    ("bounded_size", length <= 512);
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

let run _context = function
  | Core_payload.Text text ->
      let metrics =
        {
          Core_payload.confidence = Defaults.confidence;
          cost = Defaults.cost;
          latency_ms = 0;
        }
      in
      Lwt.return
        ( Core_payload.Text (Fmt.str "Validation: %s" (validate_text text)),
          metrics,
          [ "Validator checked the shape of the text payload." ] )
  | Core_payload.Plan steps ->
      let metrics =
        {
          Core_payload.confidence = Defaults.confidence;
          cost = Defaults.cost;
          latency_ms = 0;
        }
      in
      Lwt.return
        ( Core_payload.Text (Fmt.str "Validation: %s" (validate_plan steps)),
          metrics,
          [ "Validator checked the structural integrity of the plan." ] )
  | payload ->
      let metrics = Core_payload.zero_metrics in
      Lwt.return
        ( Core_payload.Error
            (Fmt.str
               "Validator cannot process %s"
               (Core_payload.summary payload)),
          metrics,
          [ "Validator rejected an unsupported payload." ] )

