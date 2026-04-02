type node =
  | Intake
  | Planning
  | Fan_out
  | Finalize

type route = {
  node : node;
  decision : Core_decision.t;
}

let route (config : Runtime_config.t) context payload =
  if Core_context.step_budget_exhausted context ~max_steps:config.engine.max_steps
  then { node = Finalize; decision = Stop Core_decision.Step_budget_exhausted }
  else
    match payload with
    | Core_payload.Error _ ->
        { node = Finalize; decision = Stop Core_decision.Error_payload }
    | Core_payload.Batch _ ->
        { node = Finalize; decision = Stop Core_decision.Batch_ready }
    | Core_payload.Plan _ ->
        { node = Fan_out; decision = Parallel config.routing.parallel_agents }
    | Core_payload.Text text ->
        if Core_context.has_completed_agent context config.routing.short_text_agent
           || Core_context.has_completed_agent context config.routing.planner_agent
        then { node = Finalize; decision = Stop Core_decision.No_further_route }
        else if String.length text > config.routing.long_text_threshold then
          { node = Planning; decision = Next config.routing.planner_agent }
        else { node = Intake; decision = Next config.routing.short_text_agent }
