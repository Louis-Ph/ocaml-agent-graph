module Trigger = Runtime_config.Memory.Compression.Trigger
module Budget = Runtime_config.Memory.Compression.Budget

type trigger_reason =
  | Explicit_checkpoint of int
  | Explicit_continuation of {
      last_checkpoint : int;
      interval : int;
      reply_count : int;
    }
  | Fibonacci_checkpoint of {
      first_reply : int;
      second_reply : int;
      reply_count : int;
    }

type budget = {
  compression_index : int;
  target_percent : int;
  target_summary_max_chars : int;
  target_summary_max_tokens : int option;
}

type plan = {
  policy_name : string;
  checkpoint_reply_count : int;
  trigger_reason : trigger_reason;
  budget : budget;
}

let fibonacci_number index =
  let rec loop previous current remaining =
    if remaining <= 0
    then previous
    else loop current (previous + current) (remaining - 1)
  in
  loop 1 1 (max 0 (index - 1))

let trigger_mode_label
    (compression : Runtime_config.Memory.Compression.t)
  =
  match compression.trigger.mode with
  | Trigger.Explicit_checkpoints -> "explicit_checkpoints"
  | Trigger.Fibonacci -> "fibonacci"

let budget_mode_label
    (compression : Runtime_config.Memory.Compression.t)
  =
  match compression.budget.mode with
  | Budget.Fixed_budget -> "fixed_budget"
  | Budget.Fibonacci_decay -> "fibonacci_decay"

let value_hierarchy_total_count
    (hierarchy : Runtime_config.Memory.Compression.Value_hierarchy.t)
  =
  List.length hierarchy.keep_verbatim
  + List.length hierarchy.keep_strongly
  + List.length hierarchy.compress_first
  + List.length hierarchy.drop_first

let value_hierarchy_summary
    (compression : Runtime_config.Memory.Compression.t)
  =
  let hierarchy = compression.value_hierarchy in
  Fmt.str
    "keep_verbatim=%d keep_strongly=%d compress_first=%d drop_first=%d"
    (List.length hierarchy.keep_verbatim)
    (List.length hierarchy.keep_strongly)
    (List.length hierarchy.compress_first)
    (List.length hierarchy.drop_first)

let trigger_summary
    (compression : Runtime_config.Memory.Compression.t)
  =
  match compression.trigger.mode with
  | Explicit_checkpoints ->
      Fmt.str
        "explicit checkpoints=[%s] continue_every=%d"
        (compression.trigger.reply_checkpoints
         |> List.map string_of_int
         |> String.concat ", ")
        compression.trigger.continue_every_replies
  | Fibonacci ->
      Fmt.str
        "fibonacci checkpoints starting at %d,%d"
        compression.trigger.fibonacci_first_reply
        compression.trigger.fibonacci_second_reply

let budget_summary
    (compression : Runtime_config.Memory.Compression.t)
  =
  let budget = compression.budget in
  Fmt.str
    "%s base_chars=%d min_chars=%d base_tokens=%s min_tokens=%s"
    (budget_mode_label compression)
    budget.base_summary_max_chars
    budget.min_summary_max_chars
    (match budget.base_summary_max_tokens with
     | Some value -> string_of_int value
     | None -> "none")
    (match budget.min_summary_max_tokens with
     | Some value -> string_of_int value
     | None -> "none")

let rec fibonacci_checkpoint
    ~first_reply
    ~second_reply
    ~reply_count
  =
  let rec loop previous current =
    if reply_count = previous
    then Some previous
    else if reply_count = current
    then Some current
    else if current > reply_count
    then None
    else loop current (previous + current)
  in
  if reply_count <= 0
  then None
  else loop first_reply second_reply

let trigger_reason_summary = function
  | Explicit_checkpoint reply_count ->
      Fmt.str "explicit checkpoint at reply %d" reply_count
  | Explicit_continuation { last_checkpoint; interval; reply_count } ->
      Fmt.str
        "explicit continuation every %d replies after %d (matched %d)"
        interval
        last_checkpoint
        reply_count
  | Fibonacci_checkpoint { first_reply; second_reply; reply_count } ->
      Fmt.str
        "fibonacci checkpoint seeded by %d,%d (matched %d)"
        first_reply
        second_reply
        reply_count

let budget_for_index
    (compression : Runtime_config.Memory.Compression.t)
    ~compression_index
  =
  let budget = compression.budget in
  let divisor, target_percent =
    match budget.mode with
    | Budget.Fixed_budget -> 1, 100
    | Budget.Fibonacci_decay ->
        let divisor = fibonacci_number (compression_index + 2) in
        divisor, max 1 (100 / divisor)
  in
  let target_summary_max_chars =
    max 120 (max budget.min_summary_max_chars (budget.base_summary_max_chars / divisor))
  in
  let target_summary_max_tokens =
    match budget.base_summary_max_tokens with
    | None -> None
    | Some base_tokens ->
        let min_tokens =
          match budget.min_summary_max_tokens with
          | Some value -> value
          | None -> max 1 base_tokens
        in
        Some (max 1 (max min_tokens (base_tokens / divisor)))
  in
  {
    compression_index;
    target_percent;
    target_summary_max_chars;
    target_summary_max_tokens;
  }

let plan_for_reply
    (compression : Runtime_config.Memory.Compression.t)
    ~reply_count
    ~compression_count
  =
  let next_budget =
    budget_for_index compression ~compression_index:(compression_count + 1)
  in
  let make_plan checkpoint_reply_count trigger_reason =
    Some
      {
        policy_name = compression.policy_name;
        checkpoint_reply_count;
        trigger_reason;
        budget = next_budget;
      }
  in
  match compression.trigger.mode with
  | Trigger.Explicit_checkpoints ->
      if List.mem reply_count compression.trigger.reply_checkpoints
      then make_plan reply_count (Explicit_checkpoint reply_count)
      else
        (match List.rev compression.trigger.reply_checkpoints with
         | last_checkpoint :: _ when reply_count > last_checkpoint ->
             let interval = max 1 compression.trigger.continue_every_replies in
             if (reply_count - last_checkpoint) mod interval = 0
             then
               make_plan
                 reply_count
                 (Explicit_continuation { last_checkpoint; interval; reply_count })
             else None
         | _ -> None)
  | Trigger.Fibonacci ->
      fibonacci_checkpoint
        ~first_reply:compression.trigger.fibonacci_first_reply
        ~second_reply:compression.trigger.fibonacci_second_reply
        ~reply_count
      |> Option.map (fun checkpoint_reply_count ->
             {
               policy_name = compression.policy_name;
               checkpoint_reply_count;
               trigger_reason =
                 Fibonacci_checkpoint
                   {
                     first_reply = compression.trigger.fibonacci_first_reply;
                     second_reply = compression.trigger.fibonacci_second_reply;
                     reply_count;
                   };
               budget = next_budget;
             })

let render_value_hierarchy
    (hierarchy : Runtime_config.Memory.Compression.Value_hierarchy.t)
  =
  let tier title values =
    match values with
    | [] -> None
    | _ ->
        Some
          (Fmt.str
             "%s:\n%s"
             title
             (values
              |> List.map (fun value -> "- " ^ value)
              |> String.concat "\n"))
  in
  [
    tier "Keep verbatim if present" hierarchy.keep_verbatim;
    tier "Preserve strongly" hierarchy.keep_strongly;
    tier "Compress first" hierarchy.compress_first;
    tier "Drop first under pressure" hierarchy.drop_first;
  ]
  |> List.filter_map Fun.id
  |> function
  | [] -> "No explicit value hierarchy configured."
  | blocks -> String.concat "\n\n" blocks

let plan_summary
    (compression : Runtime_config.Memory.Compression.t)
    (plan : plan)
  =
  Fmt.str
    "policy=%s trigger_mode=%s budget_mode=%s checkpoint=%d compression_index=%d target=%d%% max_chars=%d max_tokens=%s hierarchy=%s trigger=%s"
    plan.policy_name
    (trigger_mode_label compression)
    (budget_mode_label compression)
    plan.checkpoint_reply_count
    plan.budget.compression_index
    plan.budget.target_percent
    plan.budget.target_summary_max_chars
    (match plan.budget.target_summary_max_tokens with
     | Some value -> string_of_int value
     | None -> "none")
    (value_hierarchy_summary compression)
    (trigger_reason_summary plan.trigger_reason)
