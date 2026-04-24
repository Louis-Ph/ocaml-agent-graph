open Lwt.Syntax
module Napoleon = Runtime_config.Napoleon
module Role_kind = Runtime_config.Napoleon.Role_kind

module Event_label = struct
  let started = "napoleon.started"
  let plan_completed = "napoleon.plan.completed"
  let generation_started = "napoleon.generation.started"
  let role_completed = "napoleon.role.completed"
  let role_failed = "napoleon.role.failed"
  let generation_completed = "napoleon.generation.completed"
  let converged = "napoleon.converged"
  let final_completed = "napoleon.final.completed"
end

type role_output = {
  generation_index : int option;
  role_name : string;
  role_kind : Role_kind.t;
  content : string;
  metrics : Core_payload.metrics;
  latency_ms : int;
  notes : string list;
  success : bool;
}

type generation_result = {
  index : int;
  candidates : role_output list;
  reserve : role_output;
  frontier : string;
}

type result = {
  run_id : string;
  topic : string;
  generation_count : int;
  width : int;
  plan : string list;
  generations : generation_result list;
  final : role_output;
  final_payload : Core_payload.t;
  context : Core_context.t;
  pattern : Core_pattern.t;
  audit_chain : Core_audit.t;
  audit_verified : bool;
  total_latency_ms : int;
}

let timestamp_now () =
  Unix.gettimeofday () |> Unix.localtime |> fun tm ->
  Fmt.str "%04d%02d%02d%02d%02d%02d" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec

let sanitize_for_id value =
  let buffer = Buffer.create (String.length value) in
  String.iter
    (fun character ->
      match character with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' ->
          Buffer.add_char buffer (Char.lowercase_ascii character)
      | ' ' -> Buffer.add_char buffer '-'
      | _ -> ())
    value;
  match Buffer.contents buffer with "" -> "napoleon" | rendered -> rendered

let measure_latency_ms started_at =
  int_of_float ((Unix.gettimeofday () -. started_at) *. 1000.0)

let take count items =
  let rec loop remaining acc = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | item :: rest -> loop (remaining - 1) (item :: acc) rest
  in
  loop count [] items

let plan_lines = function
  | [] -> "(none)"
  | steps ->
      steps
      |> List.mapi (fun index step -> Fmt.str "%d. %s" (index + 1) step)
      |> String.concat "\n"

let frontier_from_plan plan =
  match plan with [] -> "(no plan)" | _ -> plan_lines plan

let role_kind_text kind = Role_kind.to_string kind

let role_header (role : Napoleon.Role.t) =
  Fmt.str "%s/%s" role.name (role_kind_text role.kind)

let output_header output =
  Fmt.str "%s/%s" output.role_name (role_kind_text output.role_kind)

let render_outputs outputs =
  match outputs with
  | [] -> "(none)"
  | _ ->
      outputs
      |> List.map (fun output ->
             Fmt.str "[%s confidence=%.2f latency=%dms]\n%s"
               (output_header output) output.metrics.confidence
               output.latency_ms output.content)
      |> String.concat "\n\n"

let render_generation_history generations =
  match generations with
  | [] -> "(none yet)"
  | _ ->
      generations
      |> List.map (fun generation ->
             Fmt.str "Generation %d reserve frontier:\n%s" generation.index
               generation.frontier)
      |> String.concat "\n\n"

let generation_prompt ~(topic : string) ~(plan : string list)
    ~(generation_index : int) ~(generation_count : int) ~(frontier : string)
    (role : Napoleon.Role.t) =
  Fmt.str
    "Objective:\n\
     %s\n\n\
     Plan:\n\
     %s\n\n\
     Generation: %d/%d\n\
     Role: %s\n\
     Mission: %s\n\n\
     Current evolved frontier:\n\
     %s\n\n\
     Return one concise field report with: actionable move, owned boundary, \
     key risk, validation check, and next mutation."
    topic (plan_lines plan) generation_index generation_count (role_header role)
    role.mission frontier

let reserve_prompt ~(topic : string) ~(plan : string list)
    ~(generation_index : int) ~(generation_count : int) ~(frontier : string)
    ~(candidates : role_output list) (role : Napoleon.Role.t) =
  Fmt.str
    "Objective:\n\
     %s\n\n\
     Plan:\n\
     %s\n\n\
     Generation: %d/%d\n\
     Reserve role: %s\n\
     Mission: %s\n\n\
     Previous frontier:\n\
     %s\n\n\
     Candidate reports:\n\
     %s\n\n\
     Arbitrate this generation. Select the strongest frontier for the next \
     generation, reject the most material risk, and name one mutation to carry \
     forward."
    topic (plan_lines plan) generation_index generation_count (role_header role)
    role.mission frontier
    (render_outputs candidates)

let final_prompt ~(topic : string) ~(plan : string list)
    ~(generations : generation_result list) ~(frontier : string)
    (role : Napoleon.Role.t) =
  Fmt.str
    "Objective:\n\
     %s\n\n\
     Initial plan:\n\
     %s\n\n\
     Evolution history:\n\
     %s\n\n\
     Final frontier:\n\
     %s\n\n\
     Marshal role: %s\n\
     Mission: %s\n\n\
     Produce the final operational answer. Include concrete execution steps, \
     risks, and validation checks. Be concise."
    topic (plan_lines plan)
    (render_generation_history generations)
    frontier (role_header role) role.mission

let role_messages (role : Napoleon.Role.t) prompt :
    Bulkhead_lm.Openai_types.message list =
  [
    { role = "system"; content = role.profile.system_prompt };
    { role = "user"; content = prompt };
  ]

let invoke_role ~(services : Runtime_services.t) ?generation_index
    (role : Napoleon.Role.t) prompt =
  let profile = role.profile in
  let started_at = Unix.gettimeofday () in
  let* completion =
    Llm_bulkhead_client.invoke_messages services.llm_client
      ~route_model:profile.route_model
      ~messages:(role_messages role prompt)
      ~max_tokens:profile.max_tokens
  in
  let latency_ms = measure_latency_ms started_at in
  match completion with
  | Ok completion ->
      let content = String.trim completion.content in
      let success = content <> "" in
      let metrics =
        { Core_payload.confidence = profile.confidence; cost = 0.0; latency_ms }
      in
      let notes =
        [
          Fmt.str
            "Napoleon role route_model=%s resolved_model=%s prompt_tokens=%d \
             completion_tokens=%d total_tokens=%d."
            completion.route_model completion.model
            completion.usage.prompt_tokens completion.usage.completion_tokens
            completion.usage.total_tokens;
          "Napoleon role provider access: "
          ^ Llm_bulkhead_client.route_access_summary completion.route_access;
        ]
      in
      Runtime_logger.log Runtime_logger.Info
        (Fmt.str "Napoleon role completed: %s latency=%dms" (role_header role)
           latency_ms);
      Lwt.return
        {
          generation_index;
          role_name = role.name;
          role_kind = role.kind;
          content = (if success then content else "(empty response)");
          metrics;
          latency_ms;
          notes;
          success;
        }
  | Error message ->
      Runtime_logger.log Runtime_logger.Warning
        (Fmt.str "Napoleon role failed: %s error=%s" (role_header role) message);
      Lwt.return
        {
          generation_index;
          role_name = role.name;
          role_kind = role.kind;
          content = "Error: " ^ message;
          metrics = { Core_payload.confidence = 0.0; cost = 0.0; latency_ms };
          latency_ms;
          notes = [ "Napoleon role failed to obtain a BulkheadLM response." ];
          success = false;
        }

let record_role_event context output =
  let label =
    if output.success then Event_label.role_completed
    else Event_label.role_failed
  in
  Core_context.record_event context ~label
    ~detail:
      (Fmt.str "role=%s generation=%s result=%s" (output_header output)
         (match output.generation_index with
         | None -> "final"
         | Some index -> string_of_int index)
         (Core_payload.summary (Core_payload.Text output.content)))

let contributor_role = function
  | Role_kind.Scout | Role_kind.Corps | Role_kind.Critic -> true
  | Role_kind.Reserve | Role_kind.Marshal -> false

let first_role kind roles =
  List.find_opt (fun (role : Napoleon.Role.t) -> role.kind = kind) roles

let select_roles (config : Napoleon.t) ~width =
  let contributors =
    config.roles
    |> List.filter (fun role -> contributor_role role.Napoleon.Role.kind)
    |> take width
  in
  match
    ( contributors,
      first_role Role_kind.Reserve config.roles,
      first_role Role_kind.Marshal config.roles )
  with
  | [], _, _ -> Error "Napoleon swarm requires at least one contributor role."
  | _, None, _ -> Error "Napoleon swarm requires a reserve role."
  | _, _, None -> Error "Napoleon swarm requires a marshal role."
  | contributors, Some reserve, Some marshal ->
      Ok (contributors, reserve, marshal)

let run_generation ~(services : Runtime_services.t) ~(topic : string)
    ~(plan : string list) ~(generation_index : int) ~(generation_count : int)
    ~(frontier : string) ~(contributors : Napoleon.Role.t list)
    ~(reserve : Napoleon.Role.t) context =
  Runtime_logger.log Runtime_logger.Info
    (Fmt.str "Napoleon generation %d/%d started" generation_index
       generation_count);
  let context =
    Core_context.record_event context ~label:Event_label.generation_started
      ~detail:(Fmt.str "generation=%d/%d" generation_index generation_count)
  in
  let* candidates =
    Lwt_list.map_p
      (fun role ->
        invoke_role ~services ~generation_index role
          (generation_prompt ~topic ~plan ~generation_index ~generation_count
             ~frontier role))
      contributors
  in
  let context = List.fold_left record_role_event context candidates in
  let* reserve_output =
    invoke_role ~services ~generation_index reserve
      (reserve_prompt ~topic ~plan ~generation_index ~generation_count ~frontier
         ~candidates reserve)
  in
  let context = record_role_event context reserve_output in
  let frontier = reserve_output.content in
  let context =
    Core_context.record_event context ~label:Event_label.generation_completed
      ~detail:
        (Fmt.str "generation=%d candidates=%d reserve=%s" generation_index
           (List.length candidates)
           (Core_payload.summary (Core_payload.Text frontier)))
  in
  Runtime_logger.log Runtime_logger.Info
    (Fmt.str "Napoleon generation %d/%d completed" generation_index
       generation_count);
  Lwt.return
    ( {
        index = generation_index;
        candidates;
        reserve = reserve_output;
        frontier;
      },
      context )

let output_confidence outputs =
  match outputs with
  | [] -> 0.0
  | _ ->
      let total =
        outputs
        |> List.fold_left
             (fun acc output -> acc +. output.metrics.confidence)
             0.0
      in
      total /. float_of_int (List.length outputs)

let output_latency outputs =
  outputs |> List.fold_left (fun acc output -> acc + output.latency_ms) 0

let max_candidate_confidence candidates =
  candidates
  |> List.fold_left (fun best output -> max best output.metrics.confidence) 0.0

let convergence_delta generation =
  generation.reserve.metrics.confidence
  -. max_candidate_confidence generation.candidates

let generation_converged (config : Napoleon.t) generation =
  generation.index >= 2 && generation.reserve.success
  && convergence_delta generation >= config.convergence_margin

let run ~(services : Runtime_services.t) ~(config : Runtime_config.t)
    ~(registry : Runtime_registry.t) context ~(topic : string)
    ~(pattern_id : string) ~(generations : int) ~(width : int) =
  if not config.napoleon.enabled then
    Lwt.return (Error "Napoleon swarm is disabled in runtime config.")
  else
    match select_roles config.napoleon ~width with
    | Error _ as error -> Lwt.return error
    | Ok (contributors, reserve, marshal) ->
        let started_at = Unix.gettimeofday () in
        let slug =
          let s = sanitize_for_id topic in
          if String.length s > 32 then String.sub s 0 32 else s
        in
        let run_id = Fmt.str "napoleon-%s-%s" (timestamp_now ()) slug in
        let root_env =
          Core_envelope.make ~correlation_id:run_id (Core_payload.Text topic)
        in
        let chain =
          Core_audit.empty
          |> Core_audit.append ~label:"napoleon.started"
               ~detail:
                 (Fmt.str
                    "id=%s topic=%s generations=%d width=%d pattern=%s \
                     envelope_id=%s"
                    run_id topic generations width pattern_id root_env.id)
        in
        let context =
          Core_context.record_event context ~label:Event_label.started
            ~detail:
              (Fmt.str "generations=%d width=%d contributors=%d" generations
                 width (List.length contributors))
        in
        let* planner_item =
          Runtime_engine.run_agent ~services ~config ~registry
            Core_agent_name.Planner context (Core_payload.Text topic)
        in
        let context = Core_context.record_outcome context planner_item in
        let plan =
          match planner_item.payload with
          | Core_payload.Plan steps when steps <> [] -> steps
          | Core_payload.Text text when String.trim text <> "" ->
              [ String.trim text ]
          | _ -> [ topic ]
        in
        let plan_env =
          Core_envelope.child_of root_env (Core_payload.Plan plan)
        in
        let chain =
          chain
          |> Core_audit.append ~label:"napoleon.plan.completed"
               ~detail:
                 (Fmt.str "envelope_id=%s steps=%d payload=%s" plan_env.id
                    (List.length plan)
                    (Core_payload.summary planner_item.payload))
        in
        let context =
          Core_context.record_event context ~label:Event_label.plan_completed
            ~detail:(Fmt.str "steps=%d" (List.length plan))
        in
        let rec loop generation_index frontier context chain acc =
          if generation_index > generations then
            Lwt.return (List.rev acc, frontier, context, chain)
          else
            let* generation, context =
              run_generation ~services ~topic ~plan ~generation_index
                ~generation_count:generations ~frontier ~contributors ~reserve
                context
            in
            let chain =
              Core_audit.append chain ~label:"napoleon.generation.completed"
                ~detail:
                  (Fmt.str
                     "generation=%d candidates=%d reserve_success=%b delta=%.4f"
                     generation.index
                     (List.length generation.candidates)
                     generation.reserve.success
                     (convergence_delta generation))
            in
            if generation_converged config.napoleon generation then
              let context =
                Core_context.record_event context ~label:Event_label.converged
                  ~detail:
                    (Fmt.str "generation=%d delta=%.4f margin=%.4f"
                       generation.index
                       (convergence_delta generation)
                       config.napoleon.convergence_margin)
              in
              let chain =
                Core_audit.append chain ~label:"napoleon.converged"
                  ~detail:
                    (Fmt.str "generation=%d delta=%.4f margin=%.4f"
                       generation.index
                       (convergence_delta generation)
                       config.napoleon.convergence_margin)
              in
              Lwt.return
                ( List.rev (generation :: acc),
                  generation.frontier,
                  context,
                  chain )
            else
              loop (generation_index + 1) generation.frontier context chain
                (generation :: acc)
        in
        let* generations, frontier, context, chain =
          loop 1 (frontier_from_plan plan) context chain []
        in
        let* final =
          invoke_role ~services marshal
            (final_prompt ~topic ~plan ~generations ~frontier marshal)
        in
        let context = record_role_event context final in
        let final_payload =
          if final.success then Core_payload.Text final.content
          else Core_payload.Error final.content
        in
        let context =
          Core_context.record_event context ~label:Event_label.final_completed
            ~detail:(Core_payload.summary final_payload)
        in
        let total_latency_ms = measure_latency_ms started_at in
        let all_outputs =
          final
          :: (generations
             |> List.map (fun generation ->
                    generation.reserve :: generation.candidates)
             |> List.flatten)
        in
        let success = final.success in
        let avg_confidence = output_confidence all_outputs in
        let pattern =
          Core_pattern.make ~id:pattern_id ~stability:Core_pattern.Volatile
            ~description:
              "Napoleon evolutionary swarm: parallel scouts/corps/critics, \
               reserve arbitration, marshal synthesis"
          |> Core_pattern.record_outcome ~success ~latency_ms:total_latency_ms
               ~confidence:avg_confidence
        in
        let chain =
          chain
          |> Core_audit.append ~label:"napoleon.final.completed"
               ~detail:
                 (Fmt.str "success=%b payload=%s" success
                    (Core_payload.summary final_payload))
          |> Core_audit.append ~label:"napoleon.pattern.recorded"
               ~detail:
                 (Fmt.str "pattern_id=%s success=%b fitness=%.4f" pattern_id
                    success
                    (Core_pattern.fitness pattern.Core_pattern.metrics))
        in
        let chain =
          Core_audit.append chain ~label:"napoleon.sealed"
            ~detail:
              (Fmt.str
                 "chain_length=%d head_hash=%s latency_ms=%d role_latency_ms=%d"
                 (Core_audit.length chain)
                 (Core_audit.head_hash chain)
                 total_latency_ms
                 (output_latency all_outputs))
        in
        let audit_verified = Core_audit.verify_chain chain in
        Lwt.return
          (Ok
             {
               run_id;
               topic;
               generation_count = generations |> List.length;
               width;
               plan;
               generations;
               final;
               final_payload;
               context;
               pattern;
               audit_chain = chain;
               audit_verified;
               total_latency_ms;
             })
