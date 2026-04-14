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

  let command_help_lines current_route_model =
    [
      "Commands:";
      "  /help       show the full command list";
      "  /tools      show the main operational workflows";
      "  /mesh       show the SSH, HTTP, install, and peer transport map";
      "  /inspect    show the current graph and route summary";
      "  /config     show the active client and runtime config paths";
      "  /models     list available BulkheadLM route models";
      "  /swap NAME  switch the assistant to another route model";
      "  /file PATH  attach one local text file to the next prompt";
      "  /files      list attached files";
      "  /clearfiles clear attached files";
      "  /explore    list a directory under the configured workspace root";
      "  /open PATH  preview a local text file under the workspace root";
      "  /run CMD    execute a local command under the workspace root";
      "  /graph TXT  execute the typed graph directly from this terminal";
      "  /discussion TXT  execute the graph and force the multi-agent discussion path";
      "  /decide TXT  verifiable decision: discussion → L1 consensus → L2 validation → L3 pattern";
      "  /docs TOPIC show the most relevant local docs for build, test, install, cron, swarm, messenger, ssh, http, or peer";
      "  /wizard TXT run the proactive starter wizard for a concrete goal";
      "  /ssh-human  print the SSH wrapper for the human terminal";
      "  /ssh-machine print the SSH wrapper for the machine worker";
      "  /http-server print the workflow HTTP server command";
      "  /curl       print ready-to-paste curl examples for the HTTP workflow API";
      "  /install-ssh print the SSH bootstrap installer command";
      "  /install-http print the HTTP bootstrap installer URL and curl command";
      "  /quit       exit the terminal";
      Fmt.str "Current assistant route_model: %s" current_route_model;
    ]

  let tool_lines =
    [
      "Operational workflows:";
      "  build   -> ask the assistant to update code, then run /run opam exec -- dune build @all";
      "  test    -> validate with /run opam exec -- dune runtest";
      "  graph   -> use /graph ... to execute the real typed graph from the human terminal";
      "  discussion -> use /discussion ... to run the configured multi-agent discussion workflow";
      "  decide  -> use /decide TOPIC [--rounds N] [--pattern ID] for a verifiable L0-L3 decision session";
      "  install -> start from ./run.sh or ask /wizard install local human terminal";
      "  cron    -> ask /wizard cron ... so the assistant can propose a safe schedule and commands";
      "  swarm   -> ask /wizard swarm ... and inspect the adaptive webcrawler, HTTP API, or worker mode";
      "  messenger -> wire BulkheadLM messenger connectors to the swarm spokesperson endpoint";
      "  ssh     -> inspect /ssh-human, /ssh-machine, and /install-ssh before remote execution";
      "  http    -> start /http-server, then use /curl or /install-http";
      "  peer    -> use /mesh to compare normal client/server and direct peer-style transports";
      "  docs    -> use /docs build, /docs swarm, /docs messenger, /docs ssh, /docs http, or /docs peer";
    ]

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
    [
      "Documentation shortcuts:";
      "  /docs build";
      "  /docs test";
      "  /docs install";
      "  /docs cron";
      "  /docs swarm";
      "  /docs messenger";
      "  /docs ssh";
      "  /docs http";
      "  /docs peer";
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
