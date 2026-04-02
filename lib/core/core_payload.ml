type metrics = {
  confidence : float;
  cost : float;
  latency_ms : int;
}

type t =
  | Text of string
  | Plan of string list
  | Batch of batch_item list
  | Error of string

and batch_item = {
  agent : Core_agent_name.t;
  payload : t;
  metrics : metrics;
  notes : string list;
}

let zero_metrics = {
  confidence = 0.0;
  cost = 0.0;
  latency_ms = 0;
}

let rec summary = function
  | Text text -> Fmt.str "Text(%d chars)" (String.length text)
  | Plan steps -> Fmt.str "Plan(%d steps)" (List.length steps)
  | Batch items -> Fmt.str "Batch(%d result(s))" (List.length items)
  | Error message -> Fmt.str "Error(%s)" message

let text_length = function
  | Text text -> Some (String.length text)
  | Plan _ | Batch _ | Error _ -> None

let metrics_to_string metrics =
  Fmt.str
    "confidence=%.2f cost=%.4f latency=%dms"
    metrics.confidence
    metrics.cost
    metrics.latency_ms

let rec to_pretty_string = function
  | Text text -> text
  | Plan steps ->
      steps
      |> List.mapi (fun index step -> Fmt.str "%d. %s" (index + 1) step)
      |> String.concat "\n"
      |> Fmt.str "Plan\n%s"
  | Batch items ->
      items
      |> List.map (fun item ->
             Fmt.str
               "[%s]\n%s\n%s"
               (Core_agent_name.to_string item.agent)
               (to_pretty_string item.payload)
               (metrics_to_string item.metrics))
      |> String.concat "\n\n"
  | Error message -> Fmt.str "Error: %s" message

