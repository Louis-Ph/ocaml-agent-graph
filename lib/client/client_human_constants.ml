module Command = struct
  let help = "/help"
  let tools = "/tools"
  let mesh = "/mesh"
  let inspect = "/inspect"
  let config = "/config"
  let models = "/models"
  let swap = "/swap"
  let file = "/file"
  let files = "/files"
  let clearfiles = "/clearfiles"
  let explore = "/explore"
  let open_file = "/open"
  let run = "/run"
  let graph = "/graph"
  let discussion = "/discussion"
  let decide = "/decide"
  let docs = "/docs"
  let wizard = "/wizard"
  let ssh_human = "/ssh-human"
  let ssh_machine = "/ssh-machine"
  let http_server = "/http-server"
  let curl = "/curl"
  let install_ssh = "/install-ssh"
  let install_http = "/install-http"
  let quit = "/quit"
end

module Wizard = struct
  let topics = [ "build"; "test"; "install"; "cron"; "swarm"; "messenger"; "ssh"; "http"; "peer" ]
end

let commands =
  [
    Command.help;
    Command.tools;
    Command.mesh;
    Command.inspect;
    Command.config;
    Command.models;
    Command.swap;
    Command.file;
    Command.files;
    Command.clearfiles;
    Command.explore;
    Command.open_file;
    Command.run;
    Command.graph;
    Command.discussion;
    Command.decide;
    Command.docs;
    Command.wizard;
    Command.ssh_human;
    Command.ssh_machine;
    Command.http_server;
    Command.curl;
    Command.install_ssh;
    Command.install_http;
    Command.quit;
  ]

module Text = struct
  let title = "ocaml-agent-graph terminal"

  let intro_lines =
    [
      "BulkheadLM remains the primary provider router/gateway and rudimentary-agent layer.";
      "ocaml-agent-graph composes those routed provider-facing agents into typed orchestration, graph control, install flows, and smarter swarms.";
      "The human terminal now covers local work, SSH remoting, HTTP workflow serving, and pair-style machine calls.";
    ]

  type command_entry = { usage : string; description : string }

  let command_entries =
    [ { usage = Command.help;                  description = "show this help" }
    ; { usage = Command.tools;                 description = "show operational workflow lanes" }
    ; { usage = Command.mesh;                  description = "show SSH, HTTP, and peer transport map" }
    ; { usage = Command.inspect;               description = "show graph and route summary" }
    ; { usage = Command.config;                description = "show active config paths" }
    ; { usage = Command.models;                description = "list BulkheadLM route models" }
    ; { usage = Command.swap ^ " NAME";        description = "switch to another route model" }
    ; { usage = Command.file ^ " PATH";        description = "attach a local file to the next prompt" }
    ; { usage = Command.files;                 description = "list attached files" }
    ; { usage = Command.clearfiles;            description = "clear attached files" }
    ; { usage = Command.explore ^ " PATH";     description = "list a directory" }
    ; { usage = Command.open_file ^ " PATH";   description = "preview a local file" }
    ; { usage = Command.run ^ " CMD";          description = "run one local command" }
    ; { usage = Command.graph ^ " TXT";        description = "run the typed agent graph" }
    ; { usage = Command.discussion ^ " TXT";   description = "run the multi-agent discussion" }
    ; { usage = Command.decide ^ " TXT";       description = "verifiable L0-L3 decision session" }
    ; { usage = Command.docs ^ " TOPIC";       description = "show relevant docs for a topic" }
    ; { usage = Command.wizard ^ " TXT";       description = "run the proactive starter wizard" }
    ; { usage = Command.ssh_human;             description = "print SSH human terminal command" }
    ; { usage = Command.ssh_machine;           description = "print SSH machine worker command" }
    ; { usage = Command.http_server;           description = "print HTTP workflow server command" }
    ; { usage = Command.curl;                  description = "print curl examples for the HTTP API" }
    ; { usage = Command.install_ssh;           description = "print SSH bootstrap installer" }
    ; { usage = Command.install_http;          description = "print HTTP installer URL" }
    ; { usage = Command.quit;                  description = "exit" }
    ]

  let max_command_usage_width =
    List.fold_left
      (fun w e -> max w (String.length e.usage))
      0
      command_entries

  let command_help_lines current_route_model =
    let fmt e =
      Fmt.str "  %-*s  %s" max_command_usage_width e.usage e.description
    in
    "Commands:"
    :: List.map fmt command_entries
    @ [ Fmt.str "  route: %s" current_route_model ]

  type tool_entry = { topic : string; tip : string }

  let tool_entries =
    [ { topic = "build";      tip = "ask assistant, then /run opam exec -- dune build @all" }
    ; { topic = "test";       tip = "/run opam exec -- dune runtest" }
    ; { topic = "graph";      tip = "/graph TXT  run the typed agent graph" }
    ; { topic = "discussion"; tip = "/discussion TXT  multi-agent discussion workflow" }
    ; { topic = "decide";     tip = "/decide TXT [--rounds N] [--pattern ID]  verifiable L0-L3 decision" }
    ; { topic = "install";    tip = "./run.sh  or  /wizard install local human terminal" }
    ; { topic = "cron";       tip = "/wizard cron ...  propose a safe cron schedule" }
    ; { topic = "swarm";      tip = "/wizard swarm ...  webcrawler, HTTP API, or worker mode" }
    ; { topic = "messenger";  tip = "wire BulkheadLM connectors to the swarm spokesperson" }
    ; { topic = "ssh";        tip = "/ssh-human  /ssh-machine  /install-ssh" }
    ; { topic = "http";       tip = "/http-server  then  /curl  or  /install-http" }
    ; { topic = "peer";       tip = "/mesh  compare client/server and direct peer transports" }
    ; { topic = "docs";       tip = "/docs TOPIC  show relevant docs" }
    ]

  let max_tool_topic_width =
    List.fold_left
      (fun w e -> max w (String.length e.topic))
      0
      tool_entries

  let tool_lines =
    "Workflows:"
    :: List.map
         (fun e -> Fmt.str "  %-*s  %s" max_tool_topic_width e.topic e.tip)
         tool_entries

  let wizard_lines =
    [
      "Starter wizard topics:";
      "  /wizard build the client and explain the graph";
      "  /wizard test the current repository and explain failures";
      "  /wizard install a local human terminal for a new user";
      "  /wizard cron a nightly swarm run and save logs safely";
      "  /wizard swarm execute the adaptive webcrawler remotely over ssh";
      "  /wizard messenger expose the swarm spokesperson for Telegram or WhatsApp through BulkheadLM";
      "  /wizard http expose the machine workflow API and show curl calls";
      "  /wizard peer wire two machines through ssh or http";
      Fmt.str
        "Known shorthand topics: %s"
        (String.concat ", " Wizard.topics);
    ]

  let docs_lines =
    [ "/docs build"
    ; "/docs test"
    ; "/docs install"
    ; "/docs cron"
    ; "/docs swarm"
    ; "/docs messenger"
    ; "/docs ssh"
    ; "/docs http"
    ; "/docs peer"
    ]

  let route_switched route_model =
    Fmt.str "Assistant route switched to %s" route_model

  let unknown_route route_model =
    Fmt.str
      "Unknown route_model %s. Use /models to inspect available routes."
      route_model

  let file_attached path = Fmt.str "Attached for the next prompt: %s" path
  let files_cleared = "Attached files were cleared."
  let files_empty = "No file is attached right now."
  let graph_prompt_required = "/graph expects a request to execute."
  let discussion_prompt_required = "/discussion expects a request to execute."
  let decide_prompt_required =
    "/decide expects a topic. Example: /decide Should we adopt Rust? --rounds 6"
  let discussion_disabled =
    "The discussion workflow is disabled in the runtime config. Set discussion.enabled=true in config/runtime.json, then retry."
  let goodbye = "Bye."
end
