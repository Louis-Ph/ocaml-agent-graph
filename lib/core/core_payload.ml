type metrics = {
  confidence : float;
  cost : float;
  latency_ms : int;
}

type discussion_turn = {
  speaker : string;
  round_index : int;
  content : string;
  metrics : metrics;
  notes : string list;
}

type discussion = {
  topic : string;
  agenda : string list;
  turns : discussion_turn list;
  completed_rounds : int;
  max_rounds : int;
}

type t =
  | Text of string
  | Plan of string list
  | Batch of batch_item list
  | Discussion of discussion
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
  | Discussion discussion ->
      Fmt.str
        "Discussion(%d turn(s), %d/%d round(s))"
        (List.length discussion.turns)
        discussion.completed_rounds
        discussion.max_rounds
  | Error message -> Fmt.str "Error(%s)" message

let text_length = function
  | Text text -> Some (String.length text)
  | Plan _ | Batch _ | Discussion _ | Error _ -> None

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
  | Discussion discussion ->
      let agenda =
        match discussion.agenda with
        | [] -> "(none)"
        | steps ->
            steps
            |> List.mapi (fun index step -> Fmt.str "%d. %s" (index + 1) step)
            |> String.concat "\n"
      in
      let transcript =
        match discussion.turns with
        | [] -> "(none)"
        | turns ->
            turns
            |> List.map (fun turn ->
                   Fmt.str
                     "Round %d [%s]\n%s\n%s"
                     turn.round_index
                     turn.speaker
                     turn.content
                     (metrics_to_string turn.metrics))
            |> String.concat "\n\n"
      in
      Fmt.str
        "Discussion Topic\n%s\n\nAgenda\n%s\n\nTranscript\n%s"
        discussion.topic
        agenda
        transcript
  | Error message -> Fmt.str "Error: %s" message
