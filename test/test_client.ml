open Agent_graph

let contains_substring ~substring value =
  let substring_length = String.length substring in
  let value_length = String.length value in
  let rec loop index =
    if index + substring_length > value_length then false
    else if String.sub value index substring_length = substring then true
    else loop (index + 1)
  in
  if substring_length = 0 then true else loop 0

let with_temp_dir prefix f =
  let base = Filename.concat (Filename.get_temp_dir_name ()) prefix in
  let rec choose attempt =
    let candidate = Fmt.str "%s-%d" base attempt in
    if Sys.file_exists candidate then choose (attempt + 1) else candidate
  in
  let dir = choose 0 in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> Sys.command (Fmt.str "rm -rf %s" (Filename.quote dir)) |> ignore)
    (fun () -> f dir)

let write_file path content =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel content)

let make_runtime_config route_model =
  let llm =
    {
      Config.Runtime.Llm.gateway_config_path = "/unused/bulkhead.json";
      authorization_token_plaintext = Some "sk-test";
      authorization_token_env = None;
      planner =
        {
          Config.Runtime.Llm.Agent_profile.route_model = route_model;
          system_prompt = "planner prompt";
          max_tokens = Some 128;
          confidence = 0.91;
        };
      summarizer =
        {
          Config.Runtime.Llm.Agent_profile.route_model = route_model;
          system_prompt = "summarizer prompt";
          max_tokens = Some 128;
          confidence = 0.88;
        };
      validator =
        {
          Config.Runtime.Llm.Agent_profile.route_model = route_model;
          system_prompt = "validator prompt";
          max_tokens = Some 128;
          confidence = 0.94;
        };
    }
  in
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
        Config.Runtime.Demo.task_id = "client-test-task";
        input = "unused";
      };
    llm;
  }

let make_test_backend
    ?(provider_kind = Bulkhead_lm.Config.Openai_compat)
    ?(api_base = "https://api.example.test/v1")
    route_model
  =
  Bulkhead_lm.Config_test_support.backend
    ~provider_id:"test-provider"
    ~provider_kind
    ~api_base
    ~upstream_model:route_model
    ~api_key_env:"IGNORED"
    ()

let make_llm_client route_model =
  let backend = make_test_backend route_model in
  let config =
    Bulkhead_lm.Config_test_support.sample_config
      ~virtual_keys:
        [
          Bulkhead_lm.Config_test_support.virtual_key
            ~token_plaintext:"sk-test"
            ~name:"test"
            ~allowed_routes:[ route_model ]
            ();
        ]
      ~routes:[ Bulkhead_lm.Config_test_support.route ~public_model:route_model ~backends:[ backend ] () ]
      ()
  in
  let store = Bulkhead_lm.Runtime_state.create config in
  Llm.Bulkhead_client.of_store ~authorization:"Bearer sk-test" store

let make_client_runtime route_model =
  let runtime_config = make_runtime_config route_model in
  let llm_client = make_llm_client route_model in
  let client_config =
    {
      Client.Config.graph_runtime_path = "/tmp/runtime.json";
      assistant =
        {
          Client.Config.Assistant.route_model = route_model;
          system_prompt = "assistant";
          max_tokens = Some 700;
        };
      local_ops =
        {
          Client.Config.Local_ops.workspace_root = ".";
          max_read_bytes = 32_000;
          max_exec_output_bytes = 12_000;
          command_timeout_ms = 10_000;
        };
      human_terminal =
        {
          Client.Config.Human_terminal.show_routes_on_start = true;
          conversation_keep_turns = 8;
        };
      machine_terminal = { Client.Config.Machine_terminal.worker_jobs = 4 };
      transport =
        {
          Client.Config.Transport.ssh =
            {
              Client.Config.Transport.Ssh.human_remote_command = "ssh human";
              machine_remote_command = "ssh machine";
              install_emit_command = "ssh install";
            };
          http =
            {
              Client.Config.Transport.Http.workflow =
                {
                  Client.Config.Transport.Http_workflow.base_url = "http://127.0.0.1:8087";
                  server_command = "serve-http";
                };
              distribution =
                {
                  Client.Config.Transport.Http_distribution.base_url = "http://127.0.0.1:8788";
                  server_command = "serve-dist";
                  install_url = "http://127.0.0.1:8788/install.sh";
                  archive_url = "http://127.0.0.1:8788/ocaml-agent-graph.tar.gz";
                };
            };
        };
    }
  in
  Client.Runtime.of_parts
    ~client_config_path:"/tmp/client.json"
    ~client_config
    ~runtime_config_path:"/tmp/runtime.json"
    ~runtime_config
    ~llm_client

let test_client_config_loads_prompt_and_paths () =
  with_temp_dir "agent-graph-client-config" (fun dir ->
      let prompt_dir = Filename.concat dir "prompts" in
      Unix.mkdir prompt_dir 0o755;
      let prompt_path = Filename.concat prompt_dir "assistant.md" in
      let runtime_path = Filename.concat dir "runtime.json" in
      let client_path = Filename.concat dir "client.json" in
      write_file prompt_path "assistant prompt body";
      write_file runtime_path "{}";
      write_file
        client_path
        {|
{
  "graph_runtime_path": "runtime.json",
  "assistant": {
    "route_model": "claude-sonnet",
    "system_prompt_file": "prompts/assistant.md",
    "max_tokens": 512
  },
  "local_ops": {
    "workspace_root": ".",
    "max_read_bytes": 1234,
    "max_exec_output_bytes": 2345,
    "command_timeout_ms": 3456
  },
  "human_terminal": {
    "show_routes_on_start": false,
    "conversation_keep_turns": 5
  },
  "machine_terminal": {
    "worker_jobs": 7
  },
  "transport": {
    "ssh": {
      "human_remote_command": "ssh -t host human",
      "machine_remote_command": "ssh -T host machine",
      "install_emit_command": "ssh host install"
    },
    "http": {
      "workflow": {
        "base_url": "http://mesh.example.test:8087",
        "server_command": "serve-http"
      },
      "distribution": {
        "base_url": "http://mesh.example.test:8788",
        "server_command": "serve-dist",
        "install_url": "http://mesh.example.test:8788/install.sh",
        "archive_url": "http://mesh.example.test:8788/ocaml-agent-graph.tar.gz"
      }
    }
  }
}
|};
      match Client.Config.load client_path with
      | Error message -> Alcotest.fail message
      | Ok config ->
          Alcotest.(check string)
            "prompt file loaded"
            "assistant prompt body"
            config.assistant.system_prompt;
          Alcotest.(check string)
            "runtime path resolved"
            runtime_path
            config.graph_runtime_path;
          Alcotest.(check int)
            "worker jobs loaded"
            7
            config.machine_terminal.worker_jobs;
          Alcotest.(check string)
            "ssh install loaded"
            "ssh host install"
            config.transport.ssh.install_emit_command;
          Alcotest.(check string)
            "http workflow url loaded"
            "http://mesh.example.test:8087"
            config.transport.http.workflow.base_url)

let test_client_config_supports_legacy_ssh_fallback () =
  with_temp_dir "agent-graph-client-config-legacy" (fun dir ->
      let prompt_dir = Filename.concat dir "prompts" in
      Unix.mkdir prompt_dir 0o755;
      let prompt_path = Filename.concat prompt_dir "assistant.md" in
      let runtime_path = Filename.concat dir "runtime.json" in
      let client_path = Filename.concat dir "client.json" in
      write_file prompt_path "assistant prompt body";
      write_file runtime_path "{}";
      write_file
        client_path
        {|
{
  "graph_runtime_path": "runtime.json",
  "assistant": {
    "route_model": "claude-sonnet",
    "system_prompt_file": "prompts/assistant.md"
  },
  "local_ops": {
    "workspace_root": "."
  },
  "human_terminal": {},
  "machine_terminal": {
    "worker_jobs": 3
  },
  "ssh": {
    "human_remote_command": "ssh human legacy",
    "machine_remote_command": "ssh machine legacy"
  }
}
|};
      match Client.Config.load client_path with
      | Error message -> Alcotest.fail message
      | Ok config ->
          Alcotest.(check string)
            "legacy human ssh preserved"
            "ssh human legacy"
            config.transport.ssh.human_remote_command;
          Alcotest.(check string)
            "legacy machine ssh preserved"
            "ssh machine legacy"
            config.transport.ssh.machine_remote_command)

let test_assistant_reply_parses_commands () =
  let content =
    {|
{
  "message": "Inspect the current runtime and run the tests.",
  "commands": [
    {
      "command": "/opt/homebrew/bin/opam",
      "args": ["exec", "--", "dune", "runtest"],
      "cwd": ".",
      "why": "Verify the graph after changing the config."
    }
  ]
}
|}
  in
  let message, commands = Client.Assistant.reply_body_of_content content in
  Alcotest.(check string)
    "message kept"
    "Inspect the current runtime and run the tests."
    message;
  Alcotest.(check int) "one command parsed" 1 (List.length commands);
  match commands with
  | command :: [] ->
      Alcotest.(check string)
        "command program"
        "/opt/homebrew/bin/opam"
        command.command;
      Alcotest.(check (option string))
        "command why"
        (Some "Verify the graph after changing the config.")
        command.why
  | _ -> Alcotest.fail "Expected exactly one parsed command"

let test_assistant_reply_parses_markdown_fenced_json () =
  let content =
    {|
```json
{
  "message": "Résumé prêt.",
  "commands": [
    {
      "command": "/bin/echo",
      "args": ["ok"]
    }
  ]
}
```
|}
  in
  let message, commands = Client.Assistant.reply_body_of_content content in
  Alcotest.(check string) "message kept" "Résumé prêt." message;
  Alcotest.(check int) "one command parsed" 1 (List.length commands)

let test_assistant_docs_selects_ssh_http_and_peer_references () =
  let docs =
    Client.Assistant_docs.selected_doc_specs "schedule a remote ssh http peer swarm worker"
  in
  let paths =
    docs
    |> List.map (fun (spec : Client.Assistant_docs.doc_spec) -> spec.relative_path)
  in
  Alcotest.(check bool)
    "includes local assistant playbook"
    true
    (List.mem "doc/HUMAN_TERMINAL_ASSISTANT.md" paths);
  Alcotest.(check bool)
    "includes local multi-machine guide"
    true
    (List.mem "doc/MULTI_MACHINE.md" paths);
  Alcotest.(check bool)
    "includes bulkhead ssh guide"
    true
    (List.mem "docs/SSH_REMOTE.md" paths);
  Alcotest.(check bool)
    "includes bulkhead peer guide"
    true
    (List.mem "docs/PEER_MESH.md" paths)

let test_assistant_prompt_mentions_bulkhead_hierarchy_and_docs () =
  let runtime = make_client_runtime "assistant-route" in
  let prompt =
    Client.Assistant.user_prompt
      ~request_kind:Client.Assistant.Wizard
      ~runtime
      ~attachments:[]
      "prepare a cron driven swarm run over ssh"
  in
  Alcotest.(check bool)
    "mentions hierarchy"
    true
    (contains_substring
       ~substring:"BulkheadLM is the primary provider router/gateway and rudimentary-agent layer."
       prompt);
  Alcotest.(check bool)
    "mentions swarm composition hierarchy"
    true
    (contains_substring
       ~substring:"Its routed provider-facing agents are the low-level building blocks that ocaml-agent-graph composes into typed agents, graph policies, and smarter swarms."
       prompt);
  Alcotest.(check bool)
    "mentions assistant playbook"
    true
    (contains_substring ~substring:"doc/HUMAN_TERMINAL_ASSISTANT.md" prompt);
  Alcotest.(check bool)
    "mentions http workflow transport"
    true
    (contains_substring ~substring:"http workflow" prompt)

let test_terminal_parse_command_supports_docs_and_wizard () =
  (match Client.Terminal.parse_command "/docs ssh" with
   | Client.Terminal.Show_docs (Some "ssh") -> ()
   | _ -> Alcotest.fail "Expected /docs ssh to parse as Show_docs");
  (match Client.Terminal.parse_command "/mesh" with
   | Client.Terminal.Mesh -> ()
   | _ -> Alcotest.fail "Expected /mesh to parse as Mesh");
  (match Client.Terminal.parse_command "/curl" with
   | Client.Terminal.Show_curl_examples -> ()
   | _ -> Alcotest.fail "Expected /curl to parse as Show_curl_examples");
  (match Client.Terminal.parse_command "/install-http" with
   | Client.Terminal.Show_install_http -> ()
   | _ -> Alcotest.fail "Expected /install-http to parse as Show_install_http");
  match Client.Terminal.parse_command "/wizard cron nightly swarm" with
  | Client.Terminal.Run_wizard (Some "cron nightly swarm") -> ()
  | _ -> Alcotest.fail "Expected /wizard ... to parse as Run_wizard"

let test_client_runtime_graph_summary_mentions_routes () =
  let route_model = "assistant-route" in
  let runtime = make_client_runtime route_model in
  let summary = Client.Runtime.graph_summary_text runtime in
  Alcotest.(check bool)
    "assistant route mentioned"
    true
    (contains_substring ~substring:"assistant_route_model: assistant-route" summary);
  Alcotest.(check bool)
    "route summary mentioned"
    true
    (contains_substring ~substring:"route_model=assistant-route" summary);
  Alcotest.(check bool)
    "http workflow mentioned"
    true
    (contains_substring ~substring:"transport: http_workflow=http://127.0.0.1:8087" summary)

let test_infer_http_provider_kind_recognizes_openrouter () =
  let provider_kind =
    Llm.Bulkhead_client.infer_http_provider_kind "https://openrouter.ai/api/v1"
  in
  Alcotest.(check string)
    "openrouter provider inferred"
    "openrouter_openai"
    provider_kind

let test_machine_run_lines_preserves_distinct_requests () =
  let runtime = make_client_runtime "assistant-route" in
  let lines =
    [
      {|{"id":"inspect-1","kind":"inspect_graph","request":{"include_routes":true}}|};
      {|{"id":"inspect-2","kind":"inspect_graph","request":{"include_routes":true}}|};
    ]
  in
  let outputs = Lwt_main.run (Client.Machine.run_lines runtime ~jobs:2 lines) in
  Alcotest.(check int) "two responses" 2 (List.length outputs);
  let ids =
    outputs
    |> List.filter_map (fun line ->
           match Yojson.Safe.from_string line with
           | `Assoc fields ->
               (match List.assoc_opt "id" fields with
                | Some (`String id) -> Some id
                | _ -> None)
           | _ -> None)
    |> List.sort String.compare
  in
  Alcotest.(check (list string))
    "distinct ids preserved"
    [ "inspect-1"; "inspect-2" ]
    ids

let () =
  Alcotest.run
    "agent-graph-client"
    [
      ( "client-config",
        [
          Alcotest.test_case "loads prompt and paths" `Quick test_client_config_loads_prompt_and_paths;
          Alcotest.test_case
            "supports legacy ssh fallback"
            `Quick
            test_client_config_supports_legacy_ssh_fallback;
        ] );
      ( "assistant",
        [
          Alcotest.test_case
            "parses structured reply"
            `Quick
            test_assistant_reply_parses_commands;
          Alcotest.test_case
            "parses markdown fenced json"
            `Quick
            test_assistant_reply_parses_markdown_fenced_json;
          Alcotest.test_case
            "selects ssh http and peer docs"
            `Quick
            test_assistant_docs_selects_ssh_http_and_peer_references;
          Alcotest.test_case
            "prompt mentions hierarchy and docs"
            `Quick
            test_assistant_prompt_mentions_bulkhead_hierarchy_and_docs;
          Alcotest.test_case
            "terminal parses docs and wizard commands"
            `Quick
            test_terminal_parse_command_supports_docs_and_wizard;
        ] );
      ( "runtime",
        [
          Alcotest.test_case
            "graph summary mentions routes"
            `Quick
            test_client_runtime_graph_summary_mentions_routes;
          Alcotest.test_case
            "recognizes openrouter http endpoints"
            `Quick
            test_infer_http_provider_kind_recognizes_openrouter;
          Alcotest.test_case
            "machine run_lines preserves distinct requests"
            `Quick
            test_machine_run_lines_preserves_distinct_requests;
        ] );
    ]
