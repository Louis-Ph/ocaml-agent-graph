module Defaults = struct
  let max_steps = 3
  let confidence = 0.91
  let cost = 0.0045
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

let run _context = function
  | Core_payload.Text text ->
      let plan = plan_from_text text in
      let metrics =
        {
          Core_payload.confidence = Defaults.confidence;
          cost = Defaults.cost;
          latency_ms = 0;
        }
      in
      Lwt.return
        ( Core_payload.Plan plan,
          metrics,
          [ "Planner normalized the request into an explicit execution plan." ] )
  | payload ->
      let metrics = Core_payload.zero_metrics in
      Lwt.return
        ( Core_payload.Error
            (Fmt.str "Planner cannot process %s" (Core_payload.summary payload)),
          metrics,
          [ "Planner rejected a non-text payload." ] )

