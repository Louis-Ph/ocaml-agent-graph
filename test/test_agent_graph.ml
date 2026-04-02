open Agent_graph

let config =
  {
    Config.Runtime.engine =
      {
        Config.Runtime.Engine.timeout_seconds = 1.0;
        retry_attempts = 0;
        retry_backoff_seconds = 0.0;
        max_steps = 8;
      };
    routing =
      {
        Config.Runtime.Routing.long_text_threshold = 48;
        short_text_agent = Core.Agent_name.Summarizer;
        planner_agent = Core.Agent_name.Planner;
        parallel_agents =
          [ Core.Agent_name.Summarizer; Core.Agent_name.Validator ];
      };
    demo =
      {
        Config.Runtime.Demo.task_id = "test-task";
        input = "unused";
      };
  }

let registry = Agents.Defaults.make_registry ()

let has_prefix prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length
  && String.sub value 0 prefix_length = prefix

let run input =
  let context = Core.Context.empty ~task_id:"test-task" ~metadata:[] in
  Lwt_main.run
    (Orchestration.Orchestrator.loop
       ~config
       ~registry
       context
       (Core.Payload.Text input))

let test_short_text_path () =
  let payload, context = run "Typed orchestration for compact tasks." in
  match payload with
  | Core.Payload.Text summary ->
      Alcotest.(check bool)
        "summary prefix"
        true
        (has_prefix "Summary:" summary);
      Alcotest.(check int) "single agent execution" 1 context.step_count;
      Alcotest.(check bool)
        "summarizer completed"
        true
        (Core.Context.has_completed_agent context Core.Agent_name.Summarizer)
  | _ -> Alcotest.fail "Expected a summarized text payload"

let test_long_text_parallel_path () =
  let input =
    "Design the modules. Type the state graph. Execute the summarizer and \
     validator in parallel. Aggregate the outcomes with audit metadata."
  in
  let payload, context = run input in
  match payload with
  | Core.Payload.Batch items ->
      let agent_names =
        items
        |> List.map (fun (item : Core.Payload.batch_item) ->
               Core.Agent_name.to_string item.agent)
      in
      Alcotest.(check int) "planner plus two parallel agents" 3 context.step_count;
      Alcotest.(check int) "two aggregated results" 2 (List.length items);
      Alcotest.(check bool)
        "planner completed"
        true
        (Core.Context.has_completed_agent context Core.Agent_name.Planner);
      Alcotest.(check bool)
        "summarizer present"
        true
        (List.mem "summarizer" agent_names);
      Alcotest.(check bool)
        "validator present"
        true
        (List.mem "validator" agent_names)
  | _ -> Alcotest.fail "Expected a batch payload after parallel orchestration"

let () =
  Alcotest.run
    "agent-graph"
    [
      ("orchestrator", [ Alcotest.test_case "short text" `Quick test_short_text_path ]);
      ( "parallel",
        [ Alcotest.test_case "long text -> plan -> batch" `Quick test_long_text_parallel_path ] );
    ]
