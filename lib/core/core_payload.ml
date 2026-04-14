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
  sub_discussions : sub_discussion list;
  completed_rounds : int;
  max_rounds : int;
}

and sub_discussion = {
  sub_topic : string;
  spawned_by : string;
  spawned_at_round : int;
  discussion : discussion;
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

let is_error = function Error _ -> true | _ -> false

let is_discussion = function Discussion _ -> true | _ -> false

let rec summary = function
  | Text text -> Fmt.str "Text(%d chars)" (String.length text)
  | Plan steps -> Fmt.str "Plan(%d steps)" (List.length steps)
  | Batch items -> Fmt.str "Batch(%d result(s))" (List.length items)
  | Discussion discussion ->
      let sub_count = List.length discussion.sub_discussions in
      if sub_count = 0
      then
        Fmt.str
          "Discussion(%d turn(s), %d/%d round(s))"
          (List.length discussion.turns)
          discussion.completed_rounds
          discussion.max_rounds
      else
        Fmt.str
          "Discussion(%d turn(s), %d/%d round(s), %d sub-discussion(s))"
          (List.length discussion.turns)
          discussion.completed_rounds
          discussion.max_rounds
          sub_count
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
  | Discussion discussion -> discussion_to_pretty_string "" discussion
  | Error message -> Fmt.str "Error: %s" message

and discussion_to_pretty_string indent discussion =
  let agenda =
    match discussion.agenda with
    | [] -> indent ^ "(none)"
    | steps ->
        steps
        |> List.mapi (fun index step -> Fmt.str "%s%d. %s" indent (index + 1) step)
        |> String.concat "\n"
  in
  let transcript =
    match discussion.turns with
    | [] -> indent ^ "(none)"
    | turns ->
        turns
        |> List.map (fun turn ->
               Fmt.str
                 "%sRound %d [%s]\n%s%s\n%s%s"
                 indent
                 turn.round_index
                 turn.speaker
                 indent
                 turn.content
                 indent
                 (metrics_to_string turn.metrics))
        |> String.concat "\n\n"
  in
  let sub_text =
    match discussion.sub_discussions with
    | [] -> ""
    | subs ->
        let child_indent = indent ^ "  " in
        let blocks =
          subs
          |> List.map (fun (sub : sub_discussion) ->
                 Fmt.str
                   "\n%s--- Sub-discussion (spawned by %s at round %d) ---\n%s%sTopic: %s\n%s"
                   child_indent
                   sub.spawned_by
                   sub.spawned_at_round
                   child_indent
                   child_indent
                   sub.sub_topic
                   (discussion_to_pretty_string child_indent sub.discussion))
        in
        String.concat "\n" blocks
  in
  Fmt.str
    "%sDiscussion Topic\n%s%s\n\n%sAgenda\n%s\n\n%sTranscript\n%s%s"
    indent
    indent
    discussion.topic
    indent
    agenda
    indent
    transcript
    sub_text
