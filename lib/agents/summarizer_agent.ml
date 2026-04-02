module Defaults = struct
  let summary_word_budget = 18
  let confidence = 0.88
  let cost = 0.0032
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
        ( Core_payload.Text (Fmt.str "Summary: %s" (summarize_text text)),
          metrics,
          [ "Summarizer compressed the raw text payload." ] )
  | Core_payload.Plan steps ->
      let metrics =
        {
          Core_payload.confidence = Defaults.confidence;
          cost = Defaults.cost;
          latency_ms = 0;
        }
      in
      Lwt.return
        ( Core_payload.Text (Fmt.str "Summary: %s" (summarize_plan steps)),
          metrics,
          [ "Summarizer condensed the execution plan for downstream review." ] )
  | payload ->
      let metrics = Core_payload.zero_metrics in
      Lwt.return
        ( Core_payload.Error
            (Fmt.str
               "Summarizer cannot process %s"
               (Core_payload.summary payload)),
          metrics,
          [ "Summarizer rejected an unsupported payload." ] )

