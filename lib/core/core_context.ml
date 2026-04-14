module Agent_set = Set.Make (struct
  type t = Core_agent_name.t

  let compare = Core_agent_name.compare
end)

type event = {
  step_index : int;
  label : string;
  detail : string;
  timestamp : float;
}

type t = {
  task_id : string;
  parent_task_id : string option;
  nesting_depth : int;
  history : Core_message.t list;
  metadata : (string * string) list;
  completed_agents : Agent_set.t;
  events : event list;
  step_count : int;
}

let empty ~task_id ~metadata =
  {
    task_id;
    parent_task_id = None;
    nesting_depth = 0;
    history = [];
    metadata;
    completed_agents = Agent_set.empty;
    events = [];
    step_count = 0;
  }

let child_context context ~child_task_id =
  { (empty ~task_id:child_task_id ~metadata:context.metadata) with
    parent_task_id = Some context.task_id;
    nesting_depth = context.nesting_depth + 1;
  }

let add_message context message =
  { context with history = message :: context.history }

let record_event context ~label ~detail =
  let event =
    {
      step_index = context.step_count;
      label;
      detail;
      timestamp = Unix.gettimeofday ();
    }
  in
  { context with events = event :: context.events }

let has_completed_agent context agent =
  Agent_set.mem agent context.completed_agents

let completed_agent_names context =
  context.completed_agents
  |> Agent_set.elements
  |> List.map Core_agent_name.to_string

let record_outcome context (item : Core_payload.batch_item) =
  let next_step = context.step_count + 1 in
  let message =
    {
      Core_message.role = Agent item.agent;
      content = Core_payload.summary item.payload;
    }
  in
  let event =
    {
      step_index = next_step;
      label = "agent.completed";
      detail =
        Fmt.str
          "%s -> %s"
          (Core_agent_name.to_string item.agent)
          (Core_payload.summary item.payload);
      timestamp = Unix.gettimeofday ();
    }
  in
  {
    context with
    history = message :: context.history;
    completed_agents = Agent_set.add item.agent context.completed_agents;
    events = event :: context.events;
    step_count = next_step;
  }

let record_outcomes items context =
  List.fold_left record_outcome context items

let record_parallel_join agents context =
  let detail =
    agents |> List.map Core_agent_name.to_string |> String.concat ", "
  in
  record_event context ~label:"parallel.join" ~detail

let record_discussion_turn
    context
    (turn : Core_payload.discussion_turn)
  =
  let detail =
    Fmt.str
      "round=%d speaker=%s -> %s"
      turn.round_index
      turn.speaker
      (Core_payload.summary (Core_payload.Text turn.content))
  in
  add_message
    context
    {
      Core_message.role = Core_message.Speaker turn.speaker;
      content = turn.content;
    }
  |> record_event ~label:"discussion.turn.completed" ~detail

let record_discussion_round context ~round_index ~turn_count =
  record_event
    context
    ~label:"discussion.round.completed"
    ~detail:(Fmt.str "round=%d turns=%d" round_index turn_count)

let step_budget_exhausted context ~max_steps =
  context.step_count >= max_steps
