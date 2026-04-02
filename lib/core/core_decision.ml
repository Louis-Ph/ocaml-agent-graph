type stop_reason =
  | Batch_ready
  | Error_payload
  | Step_budget_exhausted
  | No_further_route

type t =
  | Next of Core_agent_name.t
  | Parallel of Core_agent_name.t list
  | Stop of stop_reason

let stop_reason_to_string = function
  | Batch_ready -> "batch-ready"
  | Error_payload -> "error-payload"
  | Step_budget_exhausted -> "step-budget-exhausted"
  | No_further_route -> "no-further-route"

let to_string = function
  | Next agent -> Fmt.str "Next(%s)" (Core_agent_name.to_string agent)
  | Parallel agents ->
      agents
      |> List.map Core_agent_name.to_string
      |> String.concat ", "
      |> Fmt.str "Parallel(%s)"
  | Stop reason -> Fmt.str "Stop(%s)" (stop_reason_to_string reason)

