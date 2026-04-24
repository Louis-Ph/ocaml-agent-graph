(* Tests for L1-COORDINATION (Consensus) and L2-COMPOSITION (Pipeline).
   Both layers are exercised through mock LLM services so that tests run
   offline and remain deterministic. *)

open Agent_graph
open Lwt.Syntax

(* ------------------------------------------------------------------ *)
(* Test infrastructure — mirrors test_agent_graph.ml helpers            *)
(* ------------------------------------------------------------------ *)

let make_llm_config () =
  {
    Config.Runtime.Llm.gateway_config_path = "/unused/in-tests.json";
    gateway_endpoint_url = "http://127.0.0.1:4140";
    authorization_token_plaintext = Some "sk-test";
    authorization_token_env = None;
    planner =
      {
        Config.Runtime.Llm.Agent_profile.route_model = "planner-model";
        system_prompt = "planner";
        max_tokens = Some 128;
        confidence = 0.91;
      };
    summarizer =
      {
        Config.Runtime.Llm.Agent_profile.route_model = "summarizer-model";
        system_prompt = "summarizer";
        max_tokens = Some 128;
        confidence = 0.88;
      };
    validator =
      {
        Config.Runtime.Llm.Agent_profile.route_model = "validator-model";
        system_prompt = "validator";
        max_tokens = Some 128;
        confidence = 0.94;
      };
  }

let make_config () =
  {
    Config.Runtime.engine =
      {
        Config.Runtime.Engine.timeout_seconds = 2.0;
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
    demo = { Config.Runtime.Demo.task_id = "test-task"; input = "unused" };
    llm = make_llm_config ();
    discussion = Config.Runtime.Discussion.disabled;
    napoleon = Config.Runtime.Napoleon.disabled;
    memory = Config.Runtime.Memory.disabled;
  }

let config = make_config ()
let registry = Agents.Defaults.make_registry ()

let make_napoleon_role name kind route_model confidence =
  {
    Config.Runtime.Napoleon.Role.name;
    kind;
    profile =
      {
        Config.Runtime.Llm.Agent_profile.route_model;
        system_prompt = Fmt.str "%s prompt" name;
        max_tokens = Some 128;
        confidence;
      };
    mission = Fmt.str "%s mission" name;
  }

let make_napoleon_config () =
  {
    config with
    napoleon =
      {
        Config.Runtime.Napoleon.enabled = true;
        generations = 2;
        width = 3;
        convergence_margin = 0.05;
        pattern_id = "napoleon-test";
        archive_subdir = Filename.concat "var" "napoleon";
        roles =
          [
            make_napoleon_role "light_cavalry"
              Config.Runtime.Napoleon.Role_kind.Scout "planner-model" 0.78;
            make_napoleon_role "line_corps"
              Config.Runtime.Napoleon.Role_kind.Corps "summarizer-model" 0.84;
            make_napoleon_role "flank_critic"
              Config.Runtime.Napoleon.Role_kind.Critic "validator-model" 0.88;
            make_napoleon_role "imperial_reserve"
              Config.Runtime.Napoleon.Role_kind.Reserve "validator-model" 0.92;
            make_napoleon_role "berthier_marshal"
              Config.Runtime.Napoleon.Role_kind.Marshal "summarizer-model" 0.9;
          ];
      };
  }

let make_services ?config:(cfg = config) responses =
  let backend provider_id model =
    Bulkhead_lm.Config_test_support.backend
      ~provider_id
      ~provider_kind:Bulkhead_lm.Config.Openai_compat
      ~api_base:"https://api.example.test/v1"
      ~upstream_model:model
      ~api_key_env:"IGNORED"
      ()
  in
  let routes =
    [
      Bulkhead_lm.Config_test_support.route
        ~public_model:"planner-model"
        ~backends:[ backend "planner-provider" "planner-model" ]
        ();
      Bulkhead_lm.Config_test_support.route
        ~public_model:"summarizer-model"
        ~backends:[ backend "summarizer-provider" "summarizer-model" ]
        ();
      Bulkhead_lm.Config_test_support.route
        ~public_model:"validator-model"
        ~backends:[ backend "validator-provider" "validator-model" ]
        ();
    ]
  in
  let allowed_routes =
    routes
    |> List.map (fun (r : Bulkhead_lm.Config.route) -> r.public_model)
  in
  let bulkhead_config =
    Bulkhead_lm.Config_test_support.sample_config
      ~virtual_keys:
        [
          Bulkhead_lm.Config_test_support.virtual_key
            ~token_plaintext:"sk-test"
            ~name:"test"
            ~allowed_routes
            ();
        ]
      ~routes
      ()
  in
  let provider = Bulkhead_lm.Provider_mock.make responses in
  let store =
    Bulkhead_lm.Runtime_state.create
      ~provider_factory:(fun _backend -> provider)
      bulkhead_config
  in
  let llm_client =
    Llm.Bulkhead_client.of_store ~authorization:"Bearer sk-test" store
  in
  Runtime.Services.of_llm_client ~config:cfg llm_client

let ok_response model content =
  ( model,
    Ok
      (Bulkhead_lm.Provider_mock.sample_chat_response
         ~model
         ~content
         ()) )

let err_response model =
  ( model,
    Error
      (Bulkhead_lm.Domain_error.upstream
         ~provider_id:(model ^ "-provider")
         (Printf.sprintf "mock-failure-%s" model)) )

(* ------------------------------------------------------------------ *)
(* L1 — Consensus                                                       *)
(* ------------------------------------------------------------------ *)

(* All three agents respond successfully → quorum must be reached. *)
let test_consensus_all_succeed () =
  let services =
    make_services
      [
        ok_response "planner-model"   "Step 1\nStep 2\nStep 3";
        ok_response "summarizer-model" "Summary: all good.";
        ok_response "validator-model" "Validation passed.";
      ]
  in
  let context = Core.Context.empty ~task_id:"t1" ~metadata:[] in
  let payload  = Core.Payload.Text "analyze this" in
  let agents   =
    Core.Agent_name.[ Planner; Summarizer; Validator ]
  in
  let outcome =
    Lwt_main.run
      (Orchestration.Consensus.run
         ~services
         ~config
         ~registry
         ~agents
         ~context
         ~payload)
  in
  match outcome with
  | Orchestration.Consensus.Quorum_reached { votes; _ } ->
      Alcotest.(check int) "three votes collected" 3 (List.length votes)
  | Orchestration.Consensus.No_quorum _ ->
      Alcotest.fail "expected Quorum_reached with three responding agents"

(* Two out of three agents fail → only 1 vote, required = 2, no quorum. *)
let test_consensus_majority_fails_no_quorum () =
  let services =
    make_services
      [
        ok_response  "planner-model"   "Step 1\nStep 2";
        err_response "summarizer-model";
        err_response "validator-model";
      ]
  in
  let context = Core.Context.empty ~task_id:"t2" ~metadata:[] in
  let payload  = Core.Payload.Text "analyze this" in
  let agents   =
    Core.Agent_name.[ Planner; Summarizer; Validator ]
  in
  let outcome =
    Lwt_main.run
      (Orchestration.Consensus.run
         ~services
         ~config
         ~registry
         ~agents
         ~context
         ~payload)
  in
  match outcome with
  | Orchestration.Consensus.No_quorum { required; received; _ } ->
      Alcotest.(check int) "required quorum = 2" 2 required;
      Alcotest.(check int) "received votes = 1"  1 received
  | Orchestration.Consensus.Quorum_reached _ ->
      Alcotest.fail "expected No_quorum with only one responding agent"

(* Two out of three succeed → quorum = 2, received = 2, quorum reached. *)
let test_consensus_exact_quorum () =
  let services =
    make_services
      [
        ok_response  "planner-model"   "Step 1\nStep 2";
        ok_response  "summarizer-model" "Summary: partial success.";
        err_response "validator-model";
      ]
  in
  let context = Core.Context.empty ~task_id:"t3" ~metadata:[] in
  let payload  = Core.Payload.Text "analyze this" in
  let agents   =
    Core.Agent_name.[ Planner; Summarizer; Validator ]
  in
  let outcome =
    Lwt_main.run
      (Orchestration.Consensus.run
         ~services
         ~config
         ~registry
         ~agents
         ~context
         ~payload)
  in
  match outcome with
  | Orchestration.Consensus.Quorum_reached { votes; _ } ->
      Alcotest.(check int) "two votes at exact quorum" 2 (List.length votes)
  | Orchestration.Consensus.No_quorum _ ->
      Alcotest.fail "expected Quorum_reached with two of three responding"

let test_consensus_required_quorum_formula () =
  (* Unit-test the quorum formula directly without LLM calls *)
  let f = Orchestration.Consensus.required_quorum in
  Alcotest.(check int) "1 agent  → quorum 1" 1 (f 1);
  Alcotest.(check int) "2 agents → quorum 2" 2 (f 2);
  Alcotest.(check int) "3 agents → quorum 2" 2 (f 3);
  Alcotest.(check int) "4 agents → quorum 3" 3 (f 4);
  Alcotest.(check int) "5 agents → quorum 3" 3 (f 5)

(* ------------------------------------------------------------------ *)
(* L2 — Pipeline                                                        *)
(* ------------------------------------------------------------------ *)

(* Normal two-step flow: Planner → Validator, both succeed. *)
let test_pipeline_two_step_flow () =
  let services =
    make_services
      [
        ok_response "planner-model"   "Step 1\nStep 2\nStep 3";
        ok_response "validator-model" "Validation: OK.";
      ]
  in
  let context = Core.Context.empty ~task_id:"pipe-1" ~metadata:[] in
  let payload  = Core.Payload.Text "long enough input to trigger planner path" in
  let pipeline =
    Orchestration.Pipeline.(
      empty
      |> step Core.Agent_name.Planner
      |> step Core.Agent_name.Validator)
  in
  let result_payload, result_context =
    Lwt_main.run
      (Orchestration.Pipeline.run
         ~services
         ~config
         ~registry
         ~context
         ~payload
         pipeline)
  in
  Alcotest.(check bool)
    "pipeline does not produce an error"
    false
    (Core.Payload.is_error result_payload);
  Alcotest.(check bool)
    "planner completed"
    true
    (Core.Context.has_completed_agent result_context Core.Agent_name.Planner);
  Alcotest.(check bool)
    "validator completed"
    true
    (Core.Context.has_completed_agent result_context Core.Agent_name.Validator)

(* Guard set to Fun.negate Core.Payload.is_error skips Validator when
   Planner produces an error payload. *)
let test_pipeline_guard_skips_on_error_payload () =
  let services =
    make_services
      [
        err_response "planner-model";
        ok_response  "validator-model" "should not be called";
      ]
  in
  let context = Core.Context.empty ~task_id:"pipe-2" ~metadata:[] in
  let payload  = Core.Payload.Text "trigger planner" in
  let pipeline =
    Orchestration.Pipeline.(
      empty
      |> step Core.Agent_name.Planner
      |> step ~guard:(Fun.negate Core.Payload.is_error) Core.Agent_name.Validator)
  in
  let _result_payload, result_context =
    Lwt_main.run
      (Orchestration.Pipeline.run
         ~services
         ~config
         ~registry
         ~context
         ~payload
         pipeline)
  in
  (* Planner failed, so Validator should have been skipped *)
  Alcotest.(check bool)
    "validator skipped when guard prevents execution after planner error"
    false
    (Core.Context.has_completed_agent result_context Core.Agent_name.Validator)

(* Pipeline halts immediately when a step produces Error and no guard protects it. *)
let test_pipeline_halts_on_error_without_guard () =
  let services =
    make_services
      [
        err_response "planner-model";
        ok_response  "summarizer-model" "should not be called";
      ]
  in
  let context = Core.Context.empty ~task_id:"pipe-3" ~metadata:[] in
  let payload  = Core.Payload.Text "input" in
  let pipeline =
    Orchestration.Pipeline.(
      empty
      |> step Core.Agent_name.Planner
      |> step Core.Agent_name.Summarizer)
  in
  let result_payload, result_context =
    Lwt_main.run
      (Orchestration.Pipeline.run
         ~services
         ~config
         ~registry
         ~context
         ~payload
         pipeline)
  in
  Alcotest.(check bool)
    "result is an error payload"
    true
    (Core.Payload.is_error result_payload);
  Alcotest.(check bool)
    "summarizer was not reached"
    false
    (Core.Context.has_completed_agent result_context Core.Agent_name.Summarizer)

(* Empty pipeline returns payload and context unchanged. *)
let test_pipeline_empty_is_identity () =
  let services = make_services [] in
  let context  = Core.Context.empty ~task_id:"pipe-4" ~metadata:[] in
  let payload  = Core.Payload.Text "unchanged" in
  let result_payload, _result_context =
    Lwt_main.run
      (Orchestration.Pipeline.run
         ~services
         ~config
         ~registry
         ~context
         ~payload
         Orchestration.Pipeline.empty)
  in
  Alcotest.(check string)
    "empty pipeline preserves payload summary"
    (Core.Payload.summary payload)
    (Core.Payload.summary result_payload)

(* ------------------------------------------------------------------ *)
(* Napoleon evolutionary swarm                                          *)
(* ------------------------------------------------------------------ *)

let test_napoleon_swarm_evolves_frontier () =
  let config = make_napoleon_config () in
  let services =
    make_services ~config
      [
        ok_response "planner-model" "Map the hierarchy\nAssign owned modules";
        ok_response "summarizer-model" "Marshal synthesis with validation.";
        ok_response "validator-model" "Reserve selects the typed frontier.";
      ]
  in
  let context = Core.Context.empty ~task_id:"napoleon-1" ~metadata:[] in
  match
    Lwt_main.run
      (Orchestration.Napoleon_swarm.run ~services ~config ~registry context
         ~topic:"Evolve the runtime hierarchy" ~pattern_id:"napoleon-test"
         ~generations:2 ~width:3)
  with
  | Error message -> Alcotest.fail message
  | Ok result ->
      Alcotest.(check int)
        "two generations" 2 result.generation_count;
      Alcotest.(check int) "three candidates in first generation" 3
        (match result.generations with
         | first :: _ -> List.length first.candidates
         | [] -> 0);
      Alcotest.(check bool)
        "audit verifies" true result.audit_verified;
      Alcotest.(check int)
        "pattern invocation recorded" 1
        result.pattern.Core.Pattern.metrics.invocation_count;
      Alcotest.(check bool)
        "generation event recorded" true
        (List.exists
           (fun (event : Core.Context.event) ->
             event.label = "napoleon.generation.completed")
           result.context.events);
      Alcotest.(check bool)
        "final payload is text" true
        (match result.final_payload with
         | Core.Payload.Text _ -> true
         | _ -> false)

(* ------------------------------------------------------------------ *)
(* Runner                                                               *)
(* ------------------------------------------------------------------ *)

let () =
  let open Alcotest in
  run "coordination"
    [
      ( "L1-consensus",
        [
          test_case "quorum_reached when all succeed"          `Quick test_consensus_all_succeed;
          test_case "no_quorum when majority fails"            `Quick test_consensus_majority_fails_no_quorum;
          test_case "quorum_reached at exact threshold"        `Quick test_consensus_exact_quorum;
          test_case "required_quorum formula (⌈n/2⌉+1)"       `Quick test_consensus_required_quorum_formula;
        ] );
      ( "L2-pipeline",
        [
          test_case "two-step flow succeeds"                   `Quick test_pipeline_two_step_flow;
          test_case "guard skips step on error payload"        `Quick test_pipeline_guard_skips_on_error_payload;
          test_case "halts on error without guard"             `Quick test_pipeline_halts_on_error_without_guard;
          test_case "empty pipeline is identity"               `Quick test_pipeline_empty_is_identity;
        ] );
      ( "Napoleon-swarm",
        [
          test_case "evolves frontier through reserve arbitration" `Quick
            test_napoleon_swarm_evolves_frontier;
        ] );
    ]
