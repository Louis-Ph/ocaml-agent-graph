type repo =
  | Graph_repo
  | Bulkhead_repo

type topic =
  | General
  | Build
  | Test
  | Install
  | Cron
  | Swarm
  | Messenger
  | Ssh
  | Http
  | Peer
  | Agent
  | Provider
  | Docs

type doc_spec = {
  repo : repo;
  relative_path : string;
  description : string;
  topics : topic list;
}

module Limits = struct
  let max_docs = 5
  let excerpt_chars = 1_400
end

let topic_equal left right =
  match left, right with
  | General, General
  | Build, Build
  | Test, Test
  | Install, Install
  | Cron, Cron
  | Swarm, Swarm
  | Messenger, Messenger
  | Ssh, Ssh
  | Http, Http
  | Peer, Peer
  | Agent, Agent
  | Provider, Provider
  | Docs, Docs -> true
  | _ -> false

let topic_label = function
  | General -> "general"
  | Build -> "build"
  | Test -> "test"
  | Install -> "install"
  | Cron -> "cron"
  | Swarm -> "swarm"
  | Messenger -> "messenger"
  | Ssh -> "ssh"
  | Http -> "http"
  | Peer -> "peer"
  | Agent -> "agent"
  | Provider -> "provider"
  | Docs -> "docs"

let catalog =
  [
    {
      repo = Graph_repo;
      relative_path = "doc/HUMAN_TERMINAL_ASSISTANT.md";
      description =
        "Operator playbook for the human terminal, cron, SSH, HTTP, peer wiring, and swarm execution.";
      topics =
        [ General; Build; Test; Install; Cron; Swarm; Messenger; Ssh; Http; Peer; Provider; Docs ];
    };
    {
      repo = Graph_repo;
      relative_path = "doc/MULTI_MACHINE.md";
      description =
        "Multi-machine install, HTTP workflow serving, SSH wrappers, and peer-to-peer rollout patterns.";
      topics = [ Install; Ssh; Http; Peer; Swarm; Docs; General ];
    };
    {
      repo = Graph_repo;
      relative_path = "README.md";
      description =
        "Repository overview, quick start, run.sh behavior, and BulkheadLM integration.";
      topics = [ General; Build; Install; Swarm; Messenger; Ssh; Http; Peer; Provider; Docs ];
    };
    {
      repo = Graph_repo;
      relative_path = "doc/START_HERE.md";
      description = "Beginner guide for the repository layout and first execution path.";
      topics = [ General; Build; Install; Docs ];
    };
    {
      repo = Graph_repo;
      relative_path = "doc/MAKE_YOUR_OWN_AGENT.md";
      description = "How to add a new agent and wire it into the graph.";
      topics = [ Agent; Build; Swarm; Docs ];
    };
    {
      repo = Graph_repo;
      relative_path = "demos/adaptive_webcrawler/README.md";
      description = "A swarm-style demo with scout, fetch, extractor, and reflector roles.";
      topics = [ Swarm; Agent; Build; Docs ];
    };
    {
      repo = Graph_repo;
      relative_path = "demos/professional_buyer/README.md";
      description = "A full procurement swarm that chains planning, crawling, extraction, and scoring.";
      topics = [ Swarm; Agent; Docs ];
    };
    {
      repo = Graph_repo;
      relative_path = "doc/MESSENGER_CONNECTORS.md";
      description =
        "Messenger connector architecture and the BulkheadLM-to-swarm spokesperson wiring.";
      topics = [ Messenger; Swarm; Http; Provider; Install; Docs; General ];
    };
    {
      repo = Bulkhead_repo;
      relative_path = "README.md";
      description =
        "BulkheadLM quick start, starter terminal, worker mode, and provider routing.";
      topics = [ General; Install; Provider; Ssh; Http; Peer; Docs ];
    };
    {
      repo = Bulkhead_repo;
      relative_path = "docs/SSH_REMOTE.md";
      description =
        "Human and machine SSH wrappers, remote install, and clean JSONL worker transport.";
      topics = [ Ssh; Install; Swarm; Peer; Docs; Cron ];
    };
    {
      repo = Bulkhead_repo;
      relative_path = "docs/PEER_MESH.md";
      description =
        "HTTP and SSH peering patterns, hop guards, and explicit mesh topology.";
      topics = [ Peer; Http; Ssh; Install; Provider; Docs; Swarm ];
    };
    {
      repo = Bulkhead_repo;
      relative_path = "docs/ARCHITECTURE.md";
      description =
        "Layered architecture for the gateway, terminal clients, worker mode, and admin flows.";
      topics = [ Provider; Agent; Swarm; Install; Docs ];
    };
  ]

let normalize_text text =
  text
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")
  |> String.concat "\n"

let truncate_text ~max_chars text =
  if String.length text <= max_chars then text
  else String.sub text 0 (max 0 (max_chars - 3)) ^ "..."

let repo_root (runtime : Client_runtime.t) =
  runtime.Client_runtime.client_config.local_ops.workspace_root

let bulkhead_root runtime =
  Filename.concat (Filename.dirname (repo_root runtime)) "bulkhead-lm"

let absolute_path runtime spec =
  let root =
    match spec.repo with
    | Graph_repo -> repo_root runtime
    | Bulkhead_repo -> bulkhead_root runtime
  in
  Filename.concat root spec.relative_path

let readable_file path =
  Sys.file_exists path
  &&
  try
    let channel = open_in_bin path in
    close_in_noerr channel;
    true
  with
  | Sys_error _ -> false

let contains lowered needle =
  let needle = String.lowercase_ascii needle in
  let needle_length = String.length needle in
  let rec loop index =
    if needle_length = 0 then true
    else if index + needle_length > String.length lowered then false
    else if String.sub lowered index needle_length = needle then true
    else loop (index + 1)
  in
  loop 0

let topic_keywords =
  [
    Build,
    [ "build"; "compile"; "compiler"; "construire"; "dune"; "opam"; "develop"; "dev" ];
    Test,
    [ "test"; "tests"; "tester"; "verify"; "validation"; "validate"; "preuve"; "proof" ];
    Install,
    [ "install"; "installer"; "setup"; "bootstrap"; "starter"; "configure"; "configurer"; "config"; "package" ];
    Cron,
    [ "cron"; "crontab"; "schedule"; "planifier"; "timer"; "launchd"; "nightly" ];
    Swarm,
    [ "swarm"; "essaim"; "parallel"; "parallele"; "worker"; "workers"; "crawler"; "webcrawler" ];
    Messenger,
    [ "messenger"; "telegram"; "whatsapp"; "discord"; "wechat"; "line"; "viber"; "instagram"; "google chat"; "webhook" ];
    Ssh,
    [ "ssh"; "remote"; "distant"; "wrapper"; "terminal"; "tty" ];
    Http,
    [ "http"; "https"; "server"; "curl"; "api"; "rest"; "web" ];
    Peer,
    [ "peer"; "pair"; "p2p"; "mesh"; "maillage"; "federation" ];
    Agent,
    [ "agent"; "agents"; "planner"; "summarizer"; "validator"; "graphe"; "graph" ];
    Provider,
    [ "provider"; "providers"; "fournisseur"; "route"; "route_model"; "gateway"; "backend"; "bulkhead" ];
    Docs,
    [ "doc"; "docs"; "documentation"; "document"; "readme"; "guide" ];
  ]

let matched_topics goal =
  let lowered = String.lowercase_ascii goal in
  let topics =
    topic_keywords
    |> List.filter_map (fun (topic, keywords) ->
           if List.exists (contains lowered) keywords then Some topic else None)
  in
  match topics with
  | [] -> [ General ]
  | _ -> topics

let topic_score matched spec =
  spec.topics
  |> List.fold_left
       (fun score topic ->
         if List.exists (fun matched_topic -> topic_equal matched_topic topic) matched
         then score + 1
         else score)
       0

let dedup_specs specs =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | spec :: rest ->
        if List.mem spec.relative_path seen
        then loop seen acc rest
        else loop (spec.relative_path :: seen) (spec :: acc) rest
  in
  loop [] [] specs

let take count items =
  let rec loop acc remaining = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | item :: rest -> loop (item :: acc) (remaining - 1) rest
  in
  loop [] count items

let selected_doc_specs goal =
  let matched = matched_topics goal in
  let ranked =
    catalog
    |> List.mapi (fun index spec -> topic_score matched spec, index, spec)
    |> List.sort (fun (left_score, left_index, _) (right_score, right_index, _) ->
           match compare right_score left_score with
           | 0 -> compare left_index right_index
           | other -> other)
    |> List.filter_map (fun (score, _, spec) -> if score > 0 then Some spec else None)
  in
  let defaults =
    [ "doc/HUMAN_TERMINAL_ASSISTANT.md"; "README.md"; "doc/START_HERE.md" ]
    |> List.filter_map (fun relative_path ->
           List.find_opt (fun spec -> spec.relative_path = relative_path) catalog)
  in
  let prioritized =
    match ranked with
    | [] -> defaults
    | docs ->
        (match
           List.find_opt
             (fun spec -> spec.relative_path = "doc/HUMAN_TERMINAL_ASSISTANT.md")
             catalog
         with
         | Some spec -> spec :: docs
         | None -> docs)
  in
  prioritized |> dedup_specs |> take Limits.max_docs

let read_excerpt path =
  match Config_support.load_text_file path with
  | Error _ -> None
  | Ok text ->
      Some
        (text
        |> normalize_text
        |> truncate_text ~max_chars:Limits.excerpt_chars)

let selected_doc_entries runtime ~goal =
  selected_doc_specs goal
  |> List.map (fun spec ->
         let path = absolute_path runtime spec in
         spec, path, readable_file path)

let render_doc_overview_line spec path readable =
  Fmt.str
    "- %s: %s%s"
    path
    spec.description
    (if readable then "" else " (excerpt unavailable from this runtime context)")

let doc_overview_lines runtime ~goal =
  let topics =
    matched_topics goal
    |> List.map topic_label
    |> String.concat ", "
  in
  let doc_lines =
    selected_doc_entries runtime ~goal
    |> List.map (fun (spec, path, readable) -> render_doc_overview_line spec path readable)
  in
  Fmt.str "Matched topics: %s" topics :: doc_lines

let render_doc_excerpt spec path readable =
  match readable, read_excerpt path with
  | false, _ ->
      Fmt.str
        "File: %s\nRole: %s\nExcerpt: unavailable from this runtime context."
        path
        spec.description
  | true, None -> Fmt.str "File: %s\nRole: %s\nExcerpt: unavailable." path spec.description
  | true, Some excerpt ->
      Fmt.str
        "File: %s\nRole: %s\nExcerpt:\n%s"
        path
        spec.description
        excerpt

let render_prompt_context runtime ~goal =
  let doc_entries = selected_doc_entries runtime ~goal in
  let docs_text =
    match doc_entries with
    | [] -> "(no local documentation excerpt was available)"
    | _ ->
        doc_entries
        |> List.map (fun (spec, path, readable) -> render_doc_excerpt spec path readable)
        |> String.concat "\n\n---\n\n"
  in
  String.concat
    "\n\n"
    [
      "Operating hierarchy:\n- BulkheadLM is the primary provider router/gateway and rudimentary-agent layer.\n- Its routed provider-facing agents are the low-level building blocks that ocaml-agent-graph composes into typed agents, graph policies, and smarter swarms.\n- The human terminal assistant should connect both projects to the user's operational goal.";
      Fmt.str "Workspace root:\n%s" runtime.Client_runtime.client_config.local_ops.workspace_root;
      Fmt.str "Assistant route_model:\n%s" runtime.Client_runtime.client_config.assistant.route_model;
      Fmt.str
        "Transports:\n- ssh human: %s\n- ssh machine: %s\n- ssh install: %s\n- http workflow: %s\n- http install: %s"
        runtime.client_config.transport.ssh.human_remote_command
        runtime.client_config.transport.ssh.machine_remote_command
        runtime.client_config.transport.ssh.install_emit_command
        runtime.client_config.transport.http.workflow.base_url
        runtime.client_config.transport.http.distribution.install_url;
      Fmt.str "Relevant documentation:\n%s" docs_text;
    ]
