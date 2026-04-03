open Agent_graph

let llm_config =
  {
    Config.Runtime.Llm.gateway_config_path = "/unused/in-tests.json";
    authorization_token_plaintext = Some "sk-test";
    authorization_token_env = None;
    planner =
      {
        Config.Runtime.Llm.Agent_profile.model = "planner-model";
        system_prompt = "planner";
        max_tokens = Some 128;
        confidence = 0.91;
      };
    summarizer =
      {
        Config.Runtime.Llm.Agent_profile.model = "summarizer-model";
        system_prompt = "summarizer";
        max_tokens = Some 128;
        confidence = 0.88;
      };
    validator =
      {
        Config.Runtime.Llm.Agent_profile.model = "validator-model";
        system_prompt = "validator";
        max_tokens = Some 128;
        confidence = 0.94;
      };
  }

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
    llm = llm_config;
  }

let registry = Agents.Defaults.make_registry ()

let has_prefix prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length
  && String.sub value 0 prefix_length = prefix

let make_services responses =
  let backend provider_id model =
    Aegis_lm.Config_test_support.backend
      ~provider_id
      ~provider_kind:Aegis_lm.Config.Openai_compat
      ~api_base:"https://api.example.test/v1"
      ~upstream_model:model
      ~api_key_env:"IGNORED"
      ()
  in
  let aegis_config =
    Aegis_lm.Config_test_support.sample_config
      ~virtual_keys:
        [
          Aegis_lm.Config_test_support.virtual_key
            ~token_plaintext:"sk-test"
            ~name:"test"
            ~allowed_routes:[ "planner-model"; "summarizer-model"; "validator-model" ]
            ();
        ]
      ~routes:
        [
          Aegis_lm.Config_test_support.route
            ~public_model:"planner-model"
            ~backends:[ backend "planner-provider" "planner-model" ]
            ();
          Aegis_lm.Config_test_support.route
            ~public_model:"summarizer-model"
            ~backends:[ backend "summarizer-provider" "summarizer-model" ]
            ();
          Aegis_lm.Config_test_support.route
            ~public_model:"validator-model"
            ~backends:[ backend "validator-provider" "validator-model" ]
            ();
        ]
      ()
  in
  let provider = Aegis_lm.Provider_mock.make responses in
  let store =
    Aegis_lm.Runtime_state.create
      ~provider_factory:(fun _backend -> provider)
      aegis_config
  in
  let llm_client =
    Llm.Aegis_client.of_store
      ~authorization:"Bearer sk-test"
      store
  in
  Runtime.Services.of_llm_client ~config llm_client

let run ~services input =
  let context = Core.Context.empty ~task_id:"test-task" ~metadata:[] in
  Lwt_main.run
    (Orchestration.Orchestrator.loop
       ~services
       ~config
       ~registry
       context
       (Core.Payload.Text input))

let test_short_text_path () =
  let services =
    make_services
      [
        ( "summarizer-model",
          Ok
            (Aegis_lm.Provider_mock.sample_chat_response
               ~model:"summarizer-model"
               ~content:"A short LLM summary."
               ()) );
      ]
  in
  let payload, context = run ~services "Typed orchestration for compact tasks." in
  match payload with
  | Core.Payload.Text summary ->
      Alcotest.(check bool)
        "summary prefix"
        true
        (has_prefix "Summary:" summary);
      Alcotest.(check string)
        "llm summary body"
        "Summary: A short LLM summary."
        summary;
      Alcotest.(check int) "single agent execution" 1 context.step_count;
      Alcotest.(check bool)
        "summarizer completed"
        true
        (Core.Context.has_completed_agent context Core.Agent_name.Summarizer)
  | _ -> Alcotest.fail "Expected a summarized text payload"

let test_long_text_parallel_path () =
  let services =
    make_services
      [
        ( "planner-model",
          Ok
            (Aegis_lm.Provider_mock.sample_chat_response
               ~model:"planner-model"
               ~content:
                 "Identify the modules\nDefine the typed graph\nRun summary and validation in parallel"
               ()) );
        ( "summarizer-model",
          Ok
            (Aegis_lm.Provider_mock.sample_chat_response
               ~model:"summarizer-model"
               ~content:"A compact execution summary."
               ()) );
        ( "validator-model",
          Ok
            (Aegis_lm.Provider_mock.sample_chat_response
               ~model:"validator-model"
               ~content:"PASS | strengths: typed flow | risks: monitor provider failures"
               ()) );
      ]
  in
  let input =
    "Design the modules. Type the state graph. Execute the summarizer and \
     validator in parallel. Aggregate the outcomes with audit metadata."
  in
  let payload, context = run ~services input in
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
        (List.mem "validator" agent_names);
      let rendered = Core.Payload.to_pretty_string payload in
      Alcotest.(check bool)
        "llm validator text kept"
        true
        (String.contains rendered 'P')
  | _ -> Alcotest.fail "Expected a batch payload after parallel orchestration"

let test_brave_result_parsing () =
  let html =
    {|
data: [{type:"data",data:{results:[
  {title:"24 Effect handlers",url:"https://ocaml.org/manual/5.4/effects.html"},
  {title:"GitHub - ocaml-multicore/ocaml-effects-tutorial",url:"https://github.com/ocaml-multicore/ocaml-effects-tutorial"},
  {title:"Duplicate",url:"https://ocaml.org/manual/5.4/effects.html"}
]}}]
|}
  in
  let results = Web_crawler.Search.parse_results ~query:"ocaml effects" html in
  Alcotest.(check int) "deduplicated result count" 2 (List.length results);
  match results with
  | first :: second :: [] ->
      Alcotest.(check string)
        "first domain"
        "ocaml.org"
        first.domain;
      Alcotest.(check string)
        "second url"
        "https://github.com/ocaml-multicore/ocaml-effects-tutorial"
        second.url
  | _ -> Alcotest.fail "Expected two parsed results"

let test_html_extraction_and_links () =
  let html =
    {|
<html>
  <head><title>OCaml Effects Tutorial</title></head>
  <body>
    <p>OCaml 5 effect handlers provide user-defined effects for practical control flow.</p>
    <a href="/manual/5.4/effects.html">manual</a>
    <a href="https://discuss.ocaml.org/t/tutorial-roguelike-with-effect-handlers/9422">forum</a>
  </body>
</html>
|}
  in
  let title = Web_crawler.Html.extract_title html in
  let text = Web_crawler.Html.visible_text html in
  let excerpt =
    Web_crawler.Html.excerpt_from_text
      ~keywords:[ "ocaml"; "effects"; "handlers" ]
      text
  in
  let links =
    Web_crawler.Html.extract_links
      ~base_url:"https://ocaml.org/tutorial/index.html"
      html
  in
  Alcotest.(check (option string))
    "title"
    (Some "OCaml Effects Tutorial")
    title;
  Alcotest.(check bool)
    "excerpt contains keyword"
    true
    (String.contains (String.lowercase_ascii excerpt) 'e');
  Alcotest.(check int) "link count" 2 (List.length links);
  Alcotest.(check string)
    "relative link resolved"
    "https://ocaml.org/manual/5.4/effects.html"
    (List.hd links)

let () =
  Alcotest.run
    "agent-graph"
    [
      ("orchestrator", [ Alcotest.test_case "short text" `Quick test_short_text_path ]);
      ( "parallel",
        [ Alcotest.test_case "long text -> plan -> batch" `Quick test_long_text_parallel_path ] );
      ( "crawler",
        [
          Alcotest.test_case "parse brave results" `Quick test_brave_result_parsing;
          Alcotest.test_case "extract html and links" `Quick test_html_extraction_and_links;
        ] );
    ]
