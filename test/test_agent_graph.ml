open Agent_graph
open Lwt.Syntax

let make_llm_config
    ?(planner_route_model = "planner-model")
    ?(summarizer_route_model = "summarizer-model")
    ?(validator_route_model = "validator-model")
    ()
  =
  {
    Config.Runtime.Llm.gateway_config_path = "/unused/in-tests.json";
    authorization_token_plaintext = Some "sk-test";
    authorization_token_env = None;
    planner =
      {
        Config.Runtime.Llm.Agent_profile.route_model = planner_route_model;
        system_prompt = "planner";
        max_tokens = Some 128;
        confidence = 0.91;
      };
    summarizer =
      {
        Config.Runtime.Llm.Agent_profile.route_model = summarizer_route_model;
        system_prompt = "summarizer";
        max_tokens = Some 128;
        confidence = 0.88;
      };
    validator =
      {
        Config.Runtime.Llm.Agent_profile.route_model = validator_route_model;
        system_prompt = "validator";
        max_tokens = Some 128;
        confidence = 0.94;
      };
  }

let llm_config = make_llm_config ()

let disabled_discussion = Config.Runtime.Discussion.disabled

let disabled_memory = Config.Runtime.Memory.disabled

let make_config
    ?(llm = llm_config)
    ?(discussion = disabled_discussion)
    ?(memory = disabled_memory)
    ()
  =
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
    llm;
    discussion;
    memory;
  }

let config = make_config ()

let registry = Agents.Defaults.make_registry ()

let write_file path content =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel content)

let has_prefix prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length
  && String.sub value 0 prefix_length = prefix

let contains_substring ~substring value =
  let substring_length = String.length substring in
  let value_length = String.length value in
  let rec loop index =
    if index + substring_length > value_length then false
    else if String.sub value index substring_length = substring then true
    else loop (index + 1)
  in
  if substring_length = 0 then true else loop 0

let make_discussion_config () =
  {
    Config.Runtime.Discussion.enabled = true;
    rounds = 2;
    final_agent = Core.Agent_name.Summarizer;
    participants =
      [
        {
          Config.Runtime.Discussion.Participant.name = "architect";
          profile =
            {
              Config.Runtime.Llm.Agent_profile.route_model = "architect-model";
              system_prompt = "architect";
              max_tokens = Some 96;
              confidence = 0.9;
            };
        };
        {
          Config.Runtime.Discussion.Participant.name = "critic";
          profile =
            {
              Config.Runtime.Llm.Agent_profile.route_model = "critic-model";
              system_prompt = "critic";
              max_tokens = Some 96;
              confidence = 0.92;
            };
        };
      ];
  }

let make_bulkhead_config ?routes () =
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
    match routes with
    | Some routes -> routes
    | None ->
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
    |> List.map (fun (route : Bulkhead_lm.Config.route) -> route.public_model)
  in
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

let make_services ?(config = config) ?routes responses =
  let bulkhead_config = make_bulkhead_config ?routes () in
  let provider = Bulkhead_lm.Provider_mock.make responses in
  let store =
    Bulkhead_lm.Runtime_state.create
      ~provider_factory:(fun _backend -> provider)
      bulkhead_config
  in
  let llm_client =
    Llm.Bulkhead_client.of_store
      ~authorization:"Bearer sk-test"
      store
  in
  Runtime.Services.of_llm_client ~config llm_client

let run_lwt
    ?(config = config)
    ?(task_id = "test-task")
    ?(metadata = [])
    ~services
    input
  =
  let context = Core.Context.empty ~task_id ~metadata in
  Orchestration.Orchestrator.loop
    ~services
    ~config
    ~registry
    context
    (Core.Payload.Text input)

let run ?(config = config) ?(task_id = "test-task") ?(metadata = []) ~services input =
  Lwt_main.run (run_lwt ~config ~task_id ~metadata ~services input)

let test_short_text_path () =
  let services =
    make_services
      [
        ( "summarizer-model",
          Ok
            (Bulkhead_lm.Provider_mock.sample_chat_response
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
            (Bulkhead_lm.Provider_mock.sample_chat_response
               ~model:"planner-model"
               ~content:
                 "Identify the modules\nDefine the typed graph\nRun summary and validation in parallel"
               ()) );
        ( "summarizer-model",
          Ok
            (Bulkhead_lm.Provider_mock.sample_chat_response
               ~model:"summarizer-model"
               ~content:"A compact execution summary."
               ()) );
        ( "validator-model",
          Ok
            (Bulkhead_lm.Provider_mock.sample_chat_response
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

let test_batch_notes_include_provider_access () =
  let services =
    make_services
      [
        ( "planner-model",
          Ok
            (Bulkhead_lm.Provider_mock.sample_chat_response
               ~model:"planner-model"
               ~content:"Identify modules\nValidate providers"
               ()) );
        ( "summarizer-model",
          Ok
            (Bulkhead_lm.Provider_mock.sample_chat_response
               ~model:"summarizer-model"
               ~content:"Compact summary."
               ()) );
        ( "validator-model",
          Ok
            (Bulkhead_lm.Provider_mock.sample_chat_response
               ~model:"validator-model"
               ~content:"PASS | strengths: provider trace | risks: missing env"
               ()) );
      ]
  in
  let payload, _context =
    run
      ~services
      "Plan the graph, summarize it, and validate provider access notes."
  in
  match payload with
  | Core.Payload.Batch items ->
      let summarizer_item =
        items
        |> List.find (fun (item : Core.Payload.batch_item) ->
               item.agent = Core.Agent_name.Summarizer)
      in
      let joined_notes = String.concat "\n" summarizer_item.notes in
      Alcotest.(check bool)
        "route model tracked in notes"
        true
        (contains_substring
           ~substring:"route_model=summarizer-model"
           joined_notes);
      Alcotest.(check bool)
        "provider id tracked in notes"
        true
        (contains_substring
           ~substring:"summarizer-provider [openai_compat -> summarizer-model"
           joined_notes);
      Alcotest.(check bool)
        "route access summary present"
        true
        (String.starts_with ~prefix:"Summarizer used route_model=" (List.hd summarizer_item.notes))
  | _ -> Alcotest.fail "Expected a batch payload with provider access notes"

let test_long_text_discussion_path () =
  let discussion = make_discussion_config () in
  let config = make_config ~discussion () in
  let route provider_id public_model =
    Bulkhead_lm.Config_test_support.route
      ~public_model
      ~backends:
        [
          Bulkhead_lm.Config_test_support.backend
            ~provider_id
            ~provider_kind:Bulkhead_lm.Config.Openai_compat
            ~api_base:"https://api.example.test/v1"
            ~upstream_model:public_model
            ~api_key_env:"IGNORED"
            ();
        ]
      ()
  in
  let routes =
    [
      route "planner-provider" "planner-model";
      route "summarizer-provider" "summarizer-model";
      route "validator-provider" "validator-model";
      route "architect-provider" "architect-model";
      route "critic-provider" "critic-model";
    ]
  in
  let services =
    make_services
      ~config
      ~routes
      [
        ( "planner-model",
          Ok
            (Bulkhead_lm.Provider_mock.sample_chat_response
               ~model:"planner-model"
               ~content:
                 "Define the target module hierarchy\nDebate risks and interface boundaries\nConverge on an implementation sequence"
               ()) );
        ( "architect-model",
          Ok
            (Bulkhead_lm.Provider_mock.sample_chat_response
               ~model:"architect-model"
               ~content:"Split the workflow into planner, discussion runner, and final summarizer modules."
               ()) );
        ( "critic-model",
          Ok
            (Bulkhead_lm.Provider_mock.sample_chat_response
               ~model:"critic-model"
               ~content:"Validate every discussion route up front and cover the branch with tests."
               ()) );
        ( "architect-model",
          Ok
            (Bulkhead_lm.Provider_mock.sample_chat_response
               ~model:"architect-model"
               ~content:"Keep the transcript typed so the summarizer can consume one stable payload."
               ()) );
        ( "critic-model",
          Ok
            (Bulkhead_lm.Provider_mock.sample_chat_response
               ~model:"critic-model"
               ~content:"Do not hide participant failures; record events and stop only if nobody contributes."
               ()) );
        ( "summarizer-model",
          Ok
            (Bulkhead_lm.Provider_mock.sample_chat_response
               ~model:"summarizer-model"
               ~content:"The group converged on a typed discussion workflow with explicit route validation and auditable events."
               ()) );
      ]
  in
  let payload, context =
    run
      ~config
      ~services
      "Design a group discussion workflow of multiple BulkheadLM agents with proper hierarchy, route validation, and a final synthesis."
  in
  match payload with
  | Core.Payload.Text summary ->
      let discussion_turn_events =
        context.Core.Context.events
        |> List.filter (fun (event : Core.Context.event) ->
               String.equal event.label "discussion.turn.completed")
      in
      Alcotest.(check string)
        "discussion final summary"
        "Summary: The group converged on a typed discussion workflow with explicit route validation and auditable events."
        summary;
      Alcotest.(check int)
        "planner and summarizer counted as top-level steps"
        2
        context.step_count;
      Alcotest.(check int)
        "four discussion turns completed"
        4
        (List.length discussion_turn_events);
      Alcotest.(check bool)
        "discussion started event recorded"
        true
        (context.Core.Context.events
         |> List.exists (fun (event : Core.Context.event) ->
                String.equal event.label "discussion.started"));
      Alcotest.(check bool)
        "architect contribution kept in events"
        true
        (discussion_turn_events
         |> List.exists (fun (event : Core.Context.event) ->
                contains_substring
                  ~substring:"speaker=architect"
                  event.detail))
  | _ ->
      Alcotest.fail
        "Expected a final summarized text payload after discussion orchestration"

let test_discussion_live_output_turn_message () =
  let turn =
    {
      Core.Payload.speaker = "architect";
      round_index = 2;
      content =
        "Split the workflow into explicit modules.\nKeep the transcript typed.";
      metrics = Core.Payload.zero_metrics;
      notes = [];
    }
  in
  let rendered =
    Orchestration.Discussion.Live_output.turn_completed_message
      ~max_rounds:4
      turn
  in
  Alcotest.(check bool)
    "header keeps round hierarchy"
    true
    (contains_substring
       ~substring:"Discussion turn 2/4 speaker=architect"
       rendered);
  Alcotest.(check bool)
    "first content line indented"
    true
    (contains_substring
       ~substring:"\n    Split the workflow into explicit modules."
       rendered);
  Alcotest.(check bool)
    "second content line indented"
    true
    (contains_substring
       ~substring:"\n    Keep the transcript typed."
       rendered)

let make_memory_config sqlite_path =
  {
    Config.Runtime.Memory.enabled = true;
    session_namespace = "test-memory";
    session_id_metadata_key = None;
    storage =
      {
        Config.Runtime.Memory.Storage.mode =
          Config.Runtime.Memory.Storage.Explicit_sqlite;
        sqlite_path = Some sqlite_path;
      };
    reload = { Config.Runtime.Memory.Reload.recent_turn_buffer = 2 };
    compression =
      {
        Config.Runtime.Memory.Compression.reply_checkpoints = [ 2 ];
        continue_every_replies = 2;
        summary_max_chars = 800;
        summary_max_tokens = Some 96;
        summary_prompt =
          "Compress the durable swarm memory into a short factual note.";
      };
    bulkhead_bridge = None;
  }

type captured_bridge_request = {
  path : string;
  session_key : string option;
  authorization : string option;
  body : Yojson.Safe.t;
}

let reserve_local_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_, port) -> port
      | _ -> failwith "Expected an INET socket")

let with_bridge_server f =
  let port = reserve_local_port () in
  let requests = ref [] in
  let stop = ref false in
  let server_socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt server_socket Unix.SO_REUSEADDR true;
  Unix.bind server_socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
  Unix.listen server_socket 8;
  let parse_header line =
    match String.split_on_char ':' line with
    | [] | [ _ ] -> None
    | name :: value ->
        Some
          ( String.lowercase_ascii (String.trim name),
            String.concat ":" value |> String.trim )
  in
  let handle_client client_socket =
    let input_channel = Unix.in_channel_of_descr client_socket in
    let output_channel = Unix.out_channel_of_descr client_socket in
    Fun.protect
      ~finally:(fun () ->
        close_in_noerr input_channel;
        close_out_noerr output_channel)
      (fun () ->
        let request_line = input_line input_channel |> String.trim in
        let rec read_headers acc =
          let line = input_line input_channel |> String.trim in
          if line = ""
          then List.rev acc
          else read_headers (line :: acc)
        in
        let headers =
          read_headers []
          |> List.filter_map parse_header
        in
        let content_length =
          match List.assoc_opt "content-length" headers with
          | Some value ->
              (match int_of_string_opt value with
               | Some length -> length
               | None -> 0)
          | None -> 0
        in
        let body_text = really_input_string input_channel content_length in
        let target =
          match String.split_on_char ' ' request_line with
          | _method :: value :: _ -> value
          | _ -> "/"
        in
        let uri =
          Uri.of_string (Fmt.str "http://127.0.0.1:%d%s" port target)
        in
        let body_json =
          try Yojson.Safe.from_string body_text with
          | Yojson.Json_error _ -> `String body_text
        in
        requests :=
          {
            path = Uri.path uri;
            session_key = Uri.get_query_param uri "session_key";
            authorization = List.assoc_opt "authorization" headers;
            body = body_json;
          }
          :: !requests;
        output_string
          output_channel
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}";
        flush output_channel)
  in
  let server_thread =
    Thread.create
      (fun () ->
        let rec loop () =
          if !stop
          then ()
          else
            try
              let client_socket, _ = Unix.accept server_socket in
              handle_client client_socket;
              loop ()
            with
            | Unix.Unix_error ((Unix.EBADF | Unix.EINVAL), _, _) when !stop -> ()
            | End_of_file when !stop -> ()
        in
        loop ())
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      stop := true;
      (try Unix.close server_socket with
       | Unix.Unix_error _ -> ());
      (try
         let wake_socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
         Unix.connect wake_socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
         Unix.close wake_socket
       with
       | Unix.Unix_error _ -> ());
      Thread.join server_thread)
    (fun () ->
      Thread.delay 0.05;
      f port requests)

let test_memory_persists_between_runs () =
  let sqlite_path = Filename.temp_file "agent-graph-memory" ".sqlite" in
  let memory = make_memory_config sqlite_path in
  let config = make_config ~memory () in
  let responses =
    [
      ( "summarizer-model",
        Ok
          (Bulkhead_lm.Provider_mock.sample_chat_response
             ~model:"summarizer-model"
             ~content:"A short LLM summary."
             ()) );
    ]
  in
  let services1 = make_services ~config responses in
  let _payload1, _context1 =
    run
      ~config
      ~services:services1
      ~task_id:"persisted-task"
      "Remember the bridge retrofit notes."
  in
  let services2 = make_services ~config responses in
  let _payload2, context2 =
    run
      ~config
      ~services:services2
      ~task_id:"persisted-task"
      "Add the new budget estimate."
  in
  let rendered_history =
    context2.Core.Context.history
    |> List.rev
    |> List.map (fun (message : Core.Message.t) -> message.content)
    |> String.concat "\n"
  in
  Alcotest.(check bool)
    "previous user input reloaded"
    true
    (contains_substring
       ~substring:"Remember the bridge retrofit notes."
       rendered_history);
  Alcotest.(check bool)
    "previous assistant reply reloaded"
    true
    (contains_substring
       ~substring:"A short LLM summary."
       rendered_history)

let test_memory_compresses_on_checkpoint () =
  let sqlite_path = Filename.temp_file "agent-graph-memory-compress" ".sqlite" in
  let memory = make_memory_config sqlite_path in
  let config = make_config ~memory () in
  let responses =
    [
      ( "summarizer-model",
        Ok
          (Bulkhead_lm.Provider_mock.sample_chat_response
             ~model:"summarizer-model"
             ~content:"Compressed durable memory."
             ()) );
    ]
  in
  let services = make_services ~config responses in
  let _ =
    run
      ~config
      ~services
      ~task_id:"checkpoint-task"
      "First memory-bearing request."
  in
  let _ =
    run
      ~config
      ~services
      ~task_id:"checkpoint-task"
      "Second memory-bearing request."
  in
  let memory_runtime =
    match services.Runtime.Services.memory_runtime with
    | Some runtime -> runtime
    | None -> Alcotest.fail "expected memory runtime to be enabled"
  in
  let session =
    Memory.Store.load_session
      memory_runtime.store
      { Memory.Store.namespace = "test-memory"; session_key = "checkpoint-task" }
      ~recent_turn_buffer:4
  in
  Alcotest.(check (option string))
    "summary created"
    (Some "Compressed durable memory.")
    session.summary;
  Alcotest.(check int) "compression count increments" 1 session.compression_count

let test_runtime_config_loads_memory_policy_file () =
  let temp_dir = Filename.temp_file "agent-graph-config" ".tmp" in
  Sys.remove temp_dir;
  Unix.mkdir temp_dir 0o755;
  let memory_policy_path = Filename.concat temp_dir "memory_policy.json" in
  let runtime_config_path = Filename.concat temp_dir "runtime.json" in
  let memory_policy =
    {|{
  "enabled": true,
  "session_namespace": "loaded-from-file",
  "session_id_metadata_key": "session_id",
  "storage": { "mode": "explicit_sqlite", "sqlite_path": "./memory.sqlite" },
  "reload": { "recent_turn_buffer": 3 },
  "compression": {
    "reply_checkpoints": [5, 8],
    "continue_every_replies": 4,
    "summary_max_chars": 1234,
    "summary_prompt": "Keep only the durable facts."
  },
  "bulkhead_bridge": {
    "endpoint_url": "http://127.0.0.1:4110/_bulkhead/control/api/memory/session",
    "session_key_prefix": "swarm",
    "authorization_token_env": "BULKHEAD_LM_ADMIN_TOKEN",
    "timeout_seconds": 4.0
  }
}|}
  in
  let runtime_json =
    {|{
  "engine": { "timeout_seconds": 1.0, "retry_attempts": 0, "retry_backoff_seconds": 0.0, "max_steps": 8 },
  "routing": {
    "long_text_threshold": 48,
    "short_text_agent": "summarizer",
    "planner_agent": "planner",
    "parallel_agents": ["summarizer", "validator"]
  },
  "llm": {
    "gateway_config_path": "/unused/in-tests.json",
    "authorization_token_plaintext": "sk-test",
    "planner": { "route_model": "planner-model", "system_prompt": "planner", "max_tokens": 128, "confidence": 0.91 },
    "summarizer": { "route_model": "summarizer-model", "system_prompt": "summarizer", "max_tokens": 128, "confidence": 0.88 },
    "validator": { "route_model": "validator-model", "system_prompt": "validator", "max_tokens": 128, "confidence": 0.94 }
  },
  "memory_policy_path": "memory_policy.json",
  "demo": { "task_id": "demo", "input": "unused" }
}|}
  in
  write_file memory_policy_path memory_policy;
  write_file runtime_config_path runtime_json;
  match Config.Runtime.load runtime_config_path with
  | Error message ->
      Alcotest.failf "expected runtime config with memory policy to load: %s" message
  | Ok loaded ->
      Alcotest.(check bool) "memory enabled" true loaded.memory.enabled;
      Alcotest.(check string)
        "memory namespace loaded"
        "loaded-from-file"
        loaded.memory.session_namespace;
      Alcotest.(check int)
        "reload buffer loaded"
        3
        loaded.memory.reload.recent_turn_buffer;
      Alcotest.(check (list int))
        "checkpoints loaded"
        [ 5; 8 ]
        loaded.memory.compression.reply_checkpoints;
      Alcotest.(check (option string))
        "session id key loaded"
        (Some "session_id")
        loaded.memory.session_id_metadata_key;
      match loaded.memory.bulkhead_bridge with
      | None -> Alcotest.fail "expected bulkhead bridge configuration to load"
      | Some bridge ->
          Alcotest.(check string)
            "bridge endpoint loaded"
            "http://127.0.0.1:4110/_bulkhead/control/api/memory/session"
            bridge.endpoint_url;
          Alcotest.(check (option string))
            "bridge prefix loaded"
            (Some "swarm")
            bridge.session_key_prefix

let test_runtime_config_loads_discussion_workflow () =
  let temp_path = Filename.temp_file "agent-graph-discussion" ".json" in
  let runtime_json =
    {|{
  "engine": { "timeout_seconds": 1.0, "retry_attempts": 0, "retry_backoff_seconds": 0.0, "max_steps": 8 },
  "routing": {
    "long_text_threshold": 48,
    "short_text_agent": "summarizer",
    "planner_agent": "planner",
    "parallel_agents": ["summarizer", "validator"]
  },
  "llm": {
    "gateway_config_path": "/unused/in-tests.json",
    "authorization_token_plaintext": "sk-test",
    "planner": { "route_model": "planner-model", "system_prompt": "planner", "max_tokens": 128, "confidence": 0.91 },
    "summarizer": { "route_model": "summarizer-model", "system_prompt": "summarizer", "max_tokens": 128, "confidence": 0.88 },
    "validator": { "route_model": "validator-model", "system_prompt": "validator", "max_tokens": 128, "confidence": 0.94 }
  },
  "discussion": {
    "enabled": true,
    "rounds": 3,
    "final_agent": "summarizer",
    "participants": [
      {
        "name": "architect",
        "route_model": "architect-model",
        "system_prompt": "architect",
        "max_tokens": 90,
        "confidence": 0.9
      },
      {
        "name": "critic",
        "route_model": "critic-model",
        "system_prompt": "critic",
        "max_tokens": 90,
        "confidence": 0.92
      }
    ]
  },
  "demo": { "task_id": "demo", "input": "unused" }
}|}
  in
  write_file temp_path runtime_json;
  match Config.Runtime.load temp_path with
  | Error message ->
      Alcotest.failf "expected discussion config to load: %s" message
  | Ok loaded ->
      Alcotest.(check bool)
        "discussion enabled"
        true
        loaded.discussion.enabled;
      Alcotest.(check int)
        "discussion rounds"
        3
        loaded.discussion.rounds;
      Alcotest.(check string)
        "discussion final agent"
        "summarizer"
        (Core.Agent_name.to_string loaded.discussion.final_agent);
      Alcotest.(check int)
        "discussion participant count"
        2
        (List.length loaded.discussion.participants)

let test_memory_bulkhead_bridge_syncs_session () =
  with_bridge_server (fun port requests ->
      let sqlite_path = Filename.temp_file "agent-graph-memory-bridge" ".sqlite" in
      let memory =
        {
          (make_memory_config sqlite_path) with
          bulkhead_bridge =
            Some
              {
                Config.Runtime.Memory.Bulkhead_bridge.endpoint_url =
                  Fmt.str
                    "http://127.0.0.1:%d/_bulkhead/control/api/memory/session"
                    port;
                session_key_prefix = Some "swarm";
                authorization_token_plaintext = Some "admin-token";
                authorization_token_env = None;
                timeout_seconds = 1.0;
              };
        }
      in
      let config = make_config ~memory () in
      let services =
        make_services
          ~config
          [
            ( "summarizer-model",
              Ok
                (Bulkhead_lm.Provider_mock.sample_chat_response
                   ~model:"summarizer-model"
                   ~content:"A short LLM summary."
                   ()) );
          ]
      in
      let _payload, context =
        Lwt_main.run
          (run_lwt
             ~config
             ~task_id:"bridge-task"
             ~services
             "Mirror this swarm memory into BulkheadLM.")
      in
      let request =
        match List.rev !requests with
        | [ request ] -> request
        | requests ->
            Alcotest.failf
              "expected exactly one bridge request, got %d"
              (List.length requests)
      in
      Alcotest.(check (option string))
        "query session key"
        (Some "swarm:test-memory:bridge-task")
        request.session_key;
      Alcotest.(check (option string))
        "authorization header"
        (Some "Bearer admin-token")
        request.authorization;
      let open Yojson.Safe.Util in
      Alcotest.(check string)
        "body session key"
        "swarm:test-memory:bridge-task"
        (request.body |> member "session_key" |> to_string);
      Alcotest.(check int)
        "body compressed turn count"
        0
        (request.body |> member "compressed_turn_count" |> to_int);
      Alcotest.(check int)
        "recent turns mirrored"
        2
        (request.body |> member "recent_turns" |> to_list |> List.length);
      Alcotest.(check bool)
        "sync event recorded"
        true
        (context.Core.Context.events
         |> List.exists (fun (event : Core.Context.event) ->
                String.equal event.label "memory.bulkhead_synced")))

let test_validate_agent_profiles_rejects_missing_route () =
  let routes =
    [
      Bulkhead_lm.Config_test_support.route
        ~public_model:"summarizer-model"
        ~backends:
          [
            Bulkhead_lm.Config_test_support.backend
              ~provider_id:"summarizer-provider"
              ~provider_kind:Bulkhead_lm.Config.Openai_compat
              ~api_base:"https://api.example.test/v1"
              ~upstream_model:"summarizer-model"
              ~api_key_env:"IGNORED"
              ();
          ]
        ();
    ]
  in
  let llm =
    make_llm_config
      ~planner_route_model:"missing-planner-route"
      ~summarizer_route_model:"summarizer-model"
      ~validator_route_model:"missing-validator-route"
      ()
  in
  let store = Bulkhead_lm.Runtime_state.create (make_bulkhead_config ~routes ()) in
  let llm_client =
    Llm.Bulkhead_client.of_store
      ~authorization:"Bearer sk-test"
      store
  in
  match Llm.Bulkhead_client.validate_agent_profiles llm_client llm with
  | Ok () -> Alcotest.fail "Expected agent profile validation to reject missing routes"
  | Error message ->
      Alcotest.(check bool)
        "planner route called out"
        true
        (contains_substring
           ~substring:"agent=planner"
           message);
      Alcotest.(check bool)
        "route_model wording kept"
        true
        (contains_substring
           ~substring:"route_model=missing-planner-route"
           message)

let test_validate_discussion_routes_rejects_missing_route () =
  let config = make_config ~discussion:(make_discussion_config ()) () in
  let store = Bulkhead_lm.Runtime_state.create (make_bulkhead_config ()) in
  let llm_client =
    Llm.Bulkhead_client.of_store
      ~authorization:"Bearer sk-test"
      store
  in
  match
    try Ok (Runtime.Services.of_llm_client ~config llm_client) with
    | Failure message -> Error message
  with
  | Ok _ ->
      Alcotest.fail
        "Expected runtime service creation to reject missing discussion routes"
  | Error message ->
      Alcotest.(check bool)
        "discussion validation prefix"
        true
        (contains_substring
           ~substring:"discussion workflow"
           message);
      Alcotest.(check bool)
        "missing architect route called out"
        true
        (contains_substring
           ~substring:"route_model=architect-model"
           message)

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
        [
          Alcotest.test_case "long text -> plan -> batch" `Quick test_long_text_parallel_path;
          Alcotest.test_case "batch notes include provider access" `Quick test_batch_notes_include_provider_access;
        ] );
      ( "discussion",
        [
          Alcotest.test_case
            "long text -> plan -> discussion -> final summary"
            `Quick
            test_long_text_discussion_path;
          Alcotest.test_case
            "formats live turn output"
            `Quick
            test_discussion_live_output_turn_message;
          Alcotest.test_case
            "loads discussion workflow config"
            `Quick
            test_runtime_config_loads_discussion_workflow;
        ] );
      ( "llm",
        [
          Alcotest.test_case
            "reject missing BulkheadLM routes"
            `Quick
            test_validate_agent_profiles_rejects_missing_route;
          Alcotest.test_case
            "reject missing discussion routes"
            `Quick
            test_validate_discussion_routes_rejects_missing_route;
        ] );
      ( "memory",
        [
          Alcotest.test_case
            "persists between runs"
            `Quick
            test_memory_persists_between_runs;
          Alcotest.test_case
            "compresses on checkpoint"
            `Quick
            test_memory_compresses_on_checkpoint;
          Alcotest.test_case
            "loads external memory policy file"
            `Quick
            test_runtime_config_loads_memory_policy_file;
          Alcotest.test_case
            "syncs durable memory into BulkheadLM"
            `Quick
            test_memory_bulkhead_bridge_syncs_session;
        ] );
      ( "crawler",
        [
          Alcotest.test_case "parse brave results" `Quick test_brave_result_parsing;
          Alcotest.test_case "extract html and links" `Quick test_html_extraction_and_links;
        ] );
    ]
