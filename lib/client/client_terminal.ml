type state = {
  active_route_model : string;
  conversation : Bulkhead_lm.Openai_types.message list;
  attachments : Client_assistant.attachment list;
  graph_session_id : string;
  graph_run_count : int;
}

type graph_request_kind =
  | Graph
  | Discussion

type command =
  | Empty
  | Help
  | Tools
  | Mesh
  | Inspect
  | Show_config
  | Show_models
  | Swap_model of string
  | Attach_file of string
  | Show_files
  | Clear_files
  | Explore_path of string
  | Open_path of string
  | Run_command of string
  | Run_graph of string
  | Run_discussion of string
  | Run_decide of string
  | Show_docs of string option
  | Run_wizard of string option
  | Show_ssh_human
  | Show_ssh_machine
  | Show_http_server
  | Show_curl_examples
  | Show_install_ssh
  | Show_install_http
  | Quit
  | Prompt of string
  | Invalid of string

let commands = Client_human_constants.commands
let print_lines lines = List.iter print_endline lines
let print_blank () = print_endline ""
let print_wrapped_lines lines = Client_ui.print_wrapped_lines ~indent:2 lines

let parse_command input =
  let trimmed = String.trim input in
  let starts prefix = String.starts_with ~prefix:(prefix ^ " ") trimmed in
  let tail prefix =
    let offset = String.length prefix + 1 in
    String.sub trimmed offset (String.length trimmed - offset) |> String.trim
  in
  if trimmed = "" then Empty
  else if trimmed = Client_human_constants.Command.help then Help
  else if trimmed = Client_human_constants.Command.tools then Tools
  else if trimmed = Client_human_constants.Command.mesh then Mesh
  else if trimmed = Client_human_constants.Command.inspect then Inspect
  else if trimmed = Client_human_constants.Command.config then Show_config
  else if trimmed = Client_human_constants.Command.models then Show_models
  else if trimmed = Client_human_constants.Command.files then Show_files
  else if trimmed = Client_human_constants.Command.clearfiles then Clear_files
  else if trimmed = Client_human_constants.Command.docs then Show_docs None
  else if starts Client_human_constants.Command.docs then
    let topic = tail Client_human_constants.Command.docs in
    if topic = "" then Show_docs None else Show_docs (Some topic)
  else if trimmed = Client_human_constants.Command.wizard then Run_wizard None
  else if starts Client_human_constants.Command.wizard then
    let goal = tail Client_human_constants.Command.wizard in
    if goal = "" then Run_wizard None else Run_wizard (Some goal)
  else if trimmed = Client_human_constants.Command.ssh_human then Show_ssh_human
  else if trimmed = Client_human_constants.Command.ssh_machine then
    Show_ssh_machine
  else if trimmed = Client_human_constants.Command.http_server then
    Show_http_server
  else if trimmed = Client_human_constants.Command.curl then Show_curl_examples
  else if trimmed = Client_human_constants.Command.install_ssh then
    Show_install_ssh
  else if trimmed = Client_human_constants.Command.install_http then
    Show_install_http
  else if trimmed = Client_human_constants.Command.quit then Quit
  else if trimmed = Client_human_constants.Command.swap then
    Invalid "/swap expects a route model."
  else if starts Client_human_constants.Command.swap then
    let route_model = tail Client_human_constants.Command.swap in
    if route_model = "" then Invalid "/swap expects a route model."
    else Swap_model route_model
  else if trimmed = Client_human_constants.Command.file then
    Invalid "/file expects a readable file path."
  else if starts Client_human_constants.Command.file then
    let path = tail Client_human_constants.Command.file in
    if path = "" then Invalid "/file expects a readable file path."
    else Attach_file path
  else if trimmed = Client_human_constants.Command.explore then Explore_path "."
  else if starts Client_human_constants.Command.explore then
    let path = tail Client_human_constants.Command.explore in
    if path = "" then Explore_path "." else Explore_path path
  else if trimmed = Client_human_constants.Command.open_file then
    Invalid "/open expects a readable file path."
  else if starts Client_human_constants.Command.open_file then
    let path = tail Client_human_constants.Command.open_file in
    if path = "" then Invalid "/open expects a readable file path."
    else Open_path path
  else if trimmed = Client_human_constants.Command.run then
    Invalid "/run expects a command, for example: /run /bin/ls -la"
  else if starts Client_human_constants.Command.run then
    let command = tail Client_human_constants.Command.run in
    if command = "" then Invalid "/run expects a command."
    else Run_command command
  else if trimmed = Client_human_constants.Command.graph then
    Invalid Client_human_constants.Text.graph_prompt_required
  else if starts Client_human_constants.Command.graph then
    let prompt = tail Client_human_constants.Command.graph in
    if prompt = "" then Invalid Client_human_constants.Text.graph_prompt_required
    else Run_graph prompt
  else if trimmed = Client_human_constants.Command.discussion then
    Invalid Client_human_constants.Text.discussion_prompt_required
  else if starts Client_human_constants.Command.discussion then
    let prompt = tail Client_human_constants.Command.discussion in
    if prompt = "" then
      Invalid Client_human_constants.Text.discussion_prompt_required
    else Run_discussion prompt
  else if trimmed = Client_human_constants.Command.decide then
    Invalid Client_human_constants.Text.decide_prompt_required
  else if starts Client_human_constants.Command.decide then
    let args = tail Client_human_constants.Command.decide in
    if args = "" then Invalid Client_human_constants.Text.decide_prompt_required
    else Run_decide args
  else Prompt trimmed

let make_graph_session_id () =
  Fmt.str "human-graph-%d" (int_of_float (Unix.gettimeofday () *. 1000.0))

let initial_state (runtime : Client_runtime.t) =
  {
    active_route_model =
      runtime.Client_runtime.client_config.assistant.route_model;
    conversation = [];
    attachments = [];
    graph_session_id = make_graph_session_id ();
    graph_run_count = 0;
  }

let update_terminal_context (runtime : Client_runtime.t) =
  Bulkhead_lm.Starter_terminal.set_context ~commands
    ~models:(Llm_bulkhead_client.route_models runtime.Client_runtime.llm_client)

let help_lines current_route_model =
  Client_human_constants.Text.command_help_lines current_route_model

let route_lines (runtime : Client_runtime.t) =
  let route_models =
    Llm_bulkhead_client.route_models runtime.Client_runtime.llm_client
  in
  match route_models with
  | [] -> [ "No BulkheadLM routes are configured." ]
  | _ ->
      route_models
      |> List.map (fun route_model ->
             match
               Llm_bulkhead_client.route_access runtime.llm_client ~route_model
             with
             | Some route_access ->
                 Llm_bulkhead_client.route_access_summary route_access
             | None -> Fmt.str "route_model=%s unavailable" route_model)

let trim_conversation (runtime : Client_runtime.t) conversation =
  let keep =
    runtime.Client_runtime.client_config.human_terminal.conversation_keep_turns
    * 2
  in
  let rec drop count items =
    if List.length items <= count then items else drop count (List.tl items)
  in
  if keep <= 0 then [] else drop keep conversation

let attachment_line (attachment : Client_assistant.attachment) =
  Fmt.str "- %s (%d bytes%s)" attachment.path attachment.bytes_read
    (if attachment.truncated then ", truncated" else "")

let prompt_for_command_execution (command : Client_assistant.command) =
  let command_line =
    match command.args with
    | [] -> command.command
    | args -> String.concat " " (command.command :: args)
  in
  (match command.why with
  | Some why ->
      print_endline (Fmt.str "Suggested command: %s\nWhy: %s" command_line why)
  | None -> print_endline (Fmt.str "Suggested command: %s" command_line));
  print_string "Run it now? [y/N] ";
  flush stdout;
  match read_line () with
  | answer ->
      let answer = String.trim answer |> String.lowercase_ascii in
      answer = "y" || answer = "yes"
  | exception End_of_file -> false

let run_exec_plan (runtime : Client_runtime.t) plan =
  Lwt_main.run
    (Client_local_ops.exec
       ~workspace_root:
         runtime.Client_runtime.client_config.local_ops.workspace_root
       ~timeout_ms:runtime.client_config.local_ops.command_timeout_ms
       ~max_output_bytes:runtime.client_config.local_ops.max_exec_output_bytes
       plan)

let print_exec_result = function
  | Ok result -> print_lines (Client_local_ops.render_exec_result result)
  | Error message -> print_endline message

let print_read_result = function
  | Ok result -> print_lines (Client_local_ops.render_read_file result)
  | Error message -> print_endline message

let print_list_result = function
  | Ok result -> print_lines (Client_local_ops.render_list_dir result)
  | Error message -> print_endline message

let print_doc_lines runtime goal =
  print_blank ();
  Client_ui.print_section "Relevant Docs"
    (Client_assistant_docs.doc_overview_lines runtime ~goal);
  print_blank ()

let render_graph_attachment attachment =
  Client_assistant.render_attachment attachment

let graph_input_with_attachments prompt_text attachments =
  match attachments with
  | [] -> prompt_text
  | _ ->
      Fmt.str
        "%s\n\nAttached files:\n%s"
        prompt_text
        (attachments
         |> List.map render_graph_attachment
         |> String.concat "\n\n")

let prepare_graph_request runtime state ~request_kind prompt_text =
  let attachments = List.rev state.attachments in
  let prompt_text =
    match request_kind with
    | Graph -> prompt_text
    | Discussion ->
        Fmt.str
          "Run the typed graph in discussion mode for the request below.\nMake the planner produce an agenda, let the configured participants debate it for the configured rounds, then return the final synthesis.\n\nRequest:\n%s"
          prompt_text
  in
  let input = graph_input_with_attachments prompt_text attachments in
  let task_id =
    Fmt.str "%s-%03d" state.graph_session_id (state.graph_run_count + 1)
  in
  let metadata =
    match runtime.Client_runtime.runtime_config.memory.session_id_metadata_key with
    | Some metadata_key -> [ metadata_key, state.graph_session_id ]
    | None -> []
  in
  task_id, metadata, input

let event_line (event : Core_context.event) =
  Fmt.str
    "%02d  %s  %s"
    event.step_index
    event.label
    event.detail

module Discussion_archive = struct
  type turn_entry = {
    heading : string;
    content : string;
  }

  let archive_subdir = Filename.concat "var" "discussions"

  let timestamp_of_tm tm =
    Fmt.str
      "%04d%02d%02d%02d%02d%02d"
      (tm.Unix.tm_year + 1900)
      (tm.Unix.tm_mon + 1)
      tm.Unix.tm_mday
      tm.Unix.tm_hour
      tm.Unix.tm_min
      tm.Unix.tm_sec

  let timestamp_now () =
    Unix.gettimeofday () |> Unix.localtime |> timestamp_of_tm

  let archive_dir (runtime : Client_runtime.t) =
    Filename.concat runtime.client_config.local_ops.workspace_root archive_subdir

  let sanitize_filename_component value =
    let buffer = Buffer.create (String.length value) in
    String.iter
      (fun character ->
        match character with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' ->
            Buffer.add_char buffer (Char.lowercase_ascii character)
        | _ -> Buffer.add_char buffer '-')
      value;
    match Buffer.contents buffer with
    | "" -> "discussion"
    | rendered -> rendered

  let filename ~timestamp ~task_id =
    Fmt.str
      "discussion-%s-%s.md"
      timestamp
      (sanitize_filename_component task_id)

  let rec ensure_directory path =
    if path = "" || path = "." || Sys.file_exists path
    then Ok ()
    else
      let parent = Filename.dirname path in
      match ensure_directory parent with
      | Error _ as error -> error
      | Ok () ->
          (try
             Unix.mkdir path 0o755;
             Ok ()
           with
           | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
           | Unix.Unix_error (error, _, _) ->
               Error
                 (Fmt.str
                    "Cannot create archive directory %s: %s"
                    path
                    (Unix.error_message error)))

  let count_current_turns (context : Core_context.t) =
    context.events
    |> List.fold_left
         (fun count (event : Core_context.event) ->
           if String.equal event.label "discussion.turn.completed"
           then count + 1
           else count)
         0

  let take count items =
    let rec loop remaining acc = function
      | _ when remaining <= 0 -> List.rev acc
      | [] -> List.rev acc
      | item :: rest -> loop (remaining - 1) (item :: acc) rest
    in
    loop count [] items

  let detail_heading detail =
    let marker = " -> " in
    let marker_length = String.length marker in
    let rec find index =
      if index + marker_length > String.length detail
      then detail
      else if String.sub detail index marker_length = marker
      then String.sub detail 0 index
      else find (index + 1)
    in
    find 0

  let current_turn_entries (context : Core_context.t) =
    let turn_count = count_current_turns context in
    let events =
      context.events
      |> List.rev
      |> List.filter (fun (event : Core_context.event) ->
             String.equal event.label "discussion.turn.completed")
    in
    let contents =
      context.history
      |> List.filter_map (fun (message : Core_message.t) ->
             match message.role with
             | Core_message.Speaker _ -> Some message.content
             | System | User | Assistant | Agent _ -> None)
      |> take turn_count
      |> List.rev
    in
    let rec combine acc events contents =
      match events, contents with
      | (event : Core_context.event) :: remaining_events, content :: remaining_contents ->
          combine
            ({ heading = detail_heading event.detail; content } :: acc)
            remaining_events
            remaining_contents
      | _ -> List.rev acc
    in
    combine [] events contents

  let render_attachment_section
      (attachment : Client_assistant.attachment)
    =
    [
      Fmt.str
        "### `%s`"
        attachment.path;
      "";
      Fmt.str
        "- bytes_read: %d"
        attachment.bytes_read;
      Fmt.str
        "- truncated: %b"
        attachment.truncated;
      "";
      "```text";
      attachment.content;
      "```";
      "";
    ]

  let render_participant_lines
      (runtime : Client_runtime.t)
    =
    runtime.runtime_config.discussion.participants
    |> List.map (fun (participant : Runtime_config.Discussion.Participant.t) ->
           let persona_version =
             match participant.persona with
             | None -> "none"
             | Some persona -> persona.version
           in
           let rules_version =
             match participant.rules with
             | None -> "none"
             | Some rules -> rules.version
           in
           Fmt.str
             "- %s -> route_model=%s max_tokens=%s confidence=%.2f persona=%s rules=%s"
             participant.name
             participant.profile.route_model
             (match participant.profile.max_tokens with
              | Some value -> string_of_int value
              | None -> "none")
             participant.profile.confidence
             persona_version
             rules_version)

  let render_markdown
      ~(runtime : Client_runtime.t)
      ~timestamp
      ~task_id
      ~graph_session_id
      ~prompt_text
      ~attachments
      ~payload
      ~(context : Core_context.t)
    =
    let completed_agents =
      match Core_context.completed_agent_names context with
      | [] -> "none"
      | names -> String.concat ", " names
    in
    let attachment_lines =
      match attachments with
      | [] -> [ "_none_" ]
      | attachments ->
          attachments
          |> List.map render_attachment_section
          |> List.flatten
    in
    let transcript_lines =
      match current_turn_entries context with
      | [] -> [ "_no discussion turn recorded_" ]
      | turns ->
          turns
          |> List.map (fun turn ->
                 [
                   Fmt.str "### %s" turn.heading;
                   "";
                   "```text";
                   turn.content;
                   "```";
                   "";
                 ])
          |> List.flatten
    in
    String.concat "\n"
      ([
         "# Discussion Archive";
         "";
         Fmt.str "- archived_at: %s" timestamp;
         Fmt.str "- task_id: %s" task_id;
         Fmt.str "- graph_session_id: %s" graph_session_id;
         Fmt.str "- step_count: %d" context.step_count;
         Fmt.str "- completed_agents: %s" completed_agents;
         Fmt.str
           "- final_payload: %s"
           (Core_payload.summary payload);
         Fmt.str
           "- rounds: %d"
           runtime.runtime_config.discussion.rounds;
         Fmt.str
           "- final_agent: %s"
           (Core_agent_name.to_string runtime.runtime_config.discussion.final_agent);
         "";
         "## Participants";
         "";
       ]
      @ render_participant_lines runtime
      @ [
          "";
          "## Prompt";
          "";
          "```text";
          prompt_text;
          "```";
          "";
          "## Attachments";
          "";
        ]
      @ attachment_lines
      @ [
          "## Transcript";
          "";
        ]
      @ transcript_lines
      @ [
          "## Final Payload";
          "";
          "```text";
          Core_payload.to_pretty_string payload;
          "```";
          "";
          "## Execution Trace";
          "";
        ]
      @ (match List.rev context.events with
         | [] -> [ "_no orchestration event recorded_" ]
         | events -> List.map event_line events))

  let write
      ~(runtime : Client_runtime.t)
      ~timestamp
      ~task_id
      ~graph_session_id
      ~prompt_text
      ~attachments
      ~payload
      ~(context : Core_context.t)
    =
    let archive_dir = archive_dir runtime in
    match ensure_directory archive_dir with
    | Error _ as error -> error
    | Ok () ->
        let archive_path =
          Filename.concat archive_dir (filename ~timestamp ~task_id)
        in
        let content =
          render_markdown
            ~runtime
            ~timestamp
            ~task_id
            ~graph_session_id
            ~prompt_text
            ~attachments
            ~payload
            ~context
        in
        (try
           Stdlib.Out_channel.with_open_bin archive_path (fun channel ->
               output_string channel content);
           Ok archive_path
         with Sys_error message ->
           Error
             (Fmt.str
                "Cannot write discussion archive %s: %s"
                archive_path
                message))
end

let run_graph_request runtime state ~request_kind prompt_text =
  if
    request_kind = Discussion
    && not runtime.Client_runtime.runtime_config.discussion.enabled
  then (
    print_endline Client_human_constants.Text.discussion_disabled;
    state)
  else
    let task_id, metadata, input =
      prepare_graph_request runtime state ~request_kind prompt_text
    in
    match
      Lwt_main.run
        (Client_machine.run_graph runtime ~task_id ~metadata input)
    with
    | payload, context ->
        let archive_path =
          match request_kind with
          | Graph -> None
          | Discussion ->
              (match
                 Discussion_archive.write
                   ~runtime
                   ~timestamp:(Discussion_archive.timestamp_now ())
                   ~task_id
                   ~graph_session_id:state.graph_session_id
                   ~prompt_text
                   ~attachments:(List.rev state.attachments)
                   ~payload
                   ~context
               with
               | Ok path -> Some path
               | Error message ->
                   print_endline message;
                   None)
        in
        print_blank ();
        Client_ui.print_section "Graph Result"
          ( [
              Fmt.str "task_id: %s" context.Core_context.task_id;
              Fmt.str "payload: %s" (Core_payload.summary payload);
              Fmt.str "completed_agents: %s"
                (match Core_context.completed_agent_names context with
                 | [] -> "none"
                 | names -> String.concat ", " names);
              Fmt.str "step_count: %d" context.Core_context.step_count;
            ]
          @ String.split_on_char '\n' (Core_payload.to_pretty_string payload) );
        print_blank ();
        Client_ui.print_section ~style:Client_ui.Style.muted "Execution Trace"
          (match List.rev context.Core_context.events with
           | [] -> [ "No orchestration event was recorded." ]
           | events -> List.map event_line events);
        (match archive_path with
        | None -> ()
        | Some path ->
            print_blank ();
            Client_ui.print_section ~style:Client_ui.Style.muted
              "Discussion Archive"
              [ path ]);
        print_blank ();
        { state with
          attachments = [];
          graph_run_count = state.graph_run_count + 1
        }

let transport_rows (runtime : Client_runtime.t) =
  [
    ("human ssh", runtime.client_config.transport.ssh.human_remote_command);
    ("worker ssh", runtime.client_config.transport.ssh.machine_remote_command);
    ("http server", runtime.client_config.transport.http.workflow.server_command);
    ("http base", runtime.client_config.transport.http.workflow.base_url);
    ("install ssh", runtime.client_config.transport.ssh.install_emit_command);
    ( "install http",
      runtime.client_config.transport.http.distribution.install_url );
  ]

let http_curl_examples (runtime : Client_runtime.t) =
  let base_url = runtime.client_config.transport.http.workflow.base_url in
  [
    Fmt.str "curl -fsS %s/health" base_url;
    Fmt.str "curl -fsS %s/v1/capabilities" base_url;
    Fmt.str
      "curl -fsS -X POST %s/v1/assistant -H 'Content-Type: application/json' \
       -d '{\"prompt\":\"Reply with OK.\"}'"
      base_url;
    Fmt.str
      "curl -fsS -X POST %s/v1/run_graph -H 'Content-Type: application/json' \
       -d '{\"task_id\":\"mesh-demo\",\"input\":\"Plan a bounded swarm \
       rollout.\"}'"
      base_url;
    Fmt.str
      "curl -fsS -X POST %s/v1/messenger/chat/completions -H 'Content-Type: \
       application/json' -d '{\"model\":\"swarm-spokesperson\",\"messages\":[{\"role\":\"user\",\"content\":\"Speak to me as the swarm spokesperson.\"}],\"stream\":false}'"
      base_url;
  ]

let print_transport_dashboard runtime =
  Client_ui.print_section ~style:Client_ui.Style.muted "Transport Map"
    [
      "human terminal -> SSH TTY session for operators";
      "worker terminal -> SSH JSONL stream for another program";
      "workflow HTTP -> one-shot JSON API for normal client/server and \
       peer-style use";
      "bootstrap -> SSH installer or HTTP installer snapshot for fresh machines";
    ];
  Client_ui.print_label_value_rows ~style:Client_ui.Style.muted
    (transport_rows runtime)

let run_assistant_request runtime state ~request_kind prompt_text =
  let attachments = List.rev state.attachments in
  let conversation = trim_conversation runtime state.conversation in
  match
    Lwt_main.run
      (Client_assistant.ask runtime ~request_kind
         ~route_model:state.active_route_model ~conversation ~attachments
         prompt_text)
  with
  | Error message ->
      print_endline message;
      { state with attachments = [] }
  | Ok reply ->
      print_blank ();
      Client_ui.print_wrapped_styled ~style:Client_ui.Style.good reply.message;
      print_endline
        (Fmt.str "route=%s model=%s tokens=%d" reply.route_model
           reply.resolved_model reply.usage.total_tokens);
      List.iter
        (fun command ->
          if prompt_for_command_execution command then (
            let plan : Client_local_ops.exec_plan =
              {
                command = command.command;
                args = command.args;
                cwd = command.cwd;
              }
            in
            print_blank ();
            print_exec_result (run_exec_plan runtime plan);
            print_blank ()))
        reply.commands;
      let conversation =
        conversation
        @ [
            { Bulkhead_lm.Openai_types.role = "user"; content = prompt_text };
            { role = "assistant"; content = reply.message };
          ]
      in
      { state with attachments = []; conversation }

let rec loop (runtime : Client_runtime.t) state =
  update_terminal_context runtime;
  let prompt = Client_ui.Prompt.bold_green (Fmt.str "%s> " state.active_route_model) in
  match
    Bulkhead_lm.Starter_terminal.read_line ~record_history:true ~prompt ()
  with
  | None -> 0
  | Some input -> (
      match parse_command input with
      | Empty -> loop runtime state
      | Help ->
          print_blank ();
          Client_ui.print_section_verbatim ~style:Client_ui.Style.muted
            "Commands" (help_lines state.active_route_model);
          print_blank ();
          loop runtime state
      | Tools ->
          print_blank ();
          Client_ui.print_section_verbatim ~style:Client_ui.Style.muted
            "Workflows" Client_human_constants.Text.tool_lines;
          print_blank ();
          loop runtime state
      | Mesh ->
          print_blank ();
          print_transport_dashboard runtime;
          print_blank ();
          loop runtime state
      | Inspect ->
          print_blank ();
          Client_ui.print_section "Graph Summary"
            (String.split_on_char '\n'
               (Client_runtime.graph_summary_text runtime));
          print_blank ();
          loop runtime state
      | Show_config ->
          print_blank ();
          Client_ui.print_section "Active Config"
            [
              Fmt.str "client_config: %s" runtime.client_config_path;
              Fmt.str "graph_runtime_config: %s" runtime.runtime_config_path;
              Fmt.str "workspace_root: %s"
                runtime.client_config.local_ops.workspace_root;
              Fmt.str "assistant_route_model: %s" state.active_route_model;
              Fmt.str "http_workflow_base_url: %s"
                runtime.client_config.transport.http.workflow.base_url;
              Fmt.str "http_install_url: %s"
                runtime.client_config.transport.http.distribution.install_url;
            ];
          print_blank ();
          loop runtime state
      | Show_models ->
          print_blank ();
          Client_ui.print_section "Route Models" (route_lines runtime);
          print_blank ();
          loop runtime state
      | Swap_model route_model -> (
          match
            Llm_bulkhead_client.route_access runtime.llm_client ~route_model
          with
          | Some _ ->
              print_endline
                (Client_human_constants.Text.route_switched route_model);
              loop runtime { state with active_route_model = route_model }
          | None ->
              print_endline
                (Client_human_constants.Text.unknown_route route_model);
              loop runtime state)
      | Attach_file path -> (
          match
            Client_local_ops.read_file
              ~workspace_root:runtime.client_config.local_ops.workspace_root
              ~max_bytes:runtime.client_config.local_ops.max_read_bytes path
          with
          | Ok attachment ->
              print_endline
                (Client_human_constants.Text.file_attached attachment.path);
              loop runtime
                { state with attachments = attachment :: state.attachments }
          | Error message ->
              print_endline message;
              loop runtime state)
      | Show_files ->
          print_blank ();
          (match List.rev state.attachments with
          | [] -> print_endline Client_human_constants.Text.files_empty
          | attachments -> print_lines (List.map attachment_line attachments));
          print_blank ();
          loop runtime state
      | Clear_files ->
          print_endline Client_human_constants.Text.files_cleared;
          loop runtime { state with attachments = [] }
      | Explore_path path ->
          print_blank ();
          Client_local_ops.list_dir
            ~workspace_root:runtime.client_config.local_ops.workspace_root path
          |> print_list_result;
          print_blank ();
          loop runtime state
      | Open_path path ->
          print_blank ();
          Client_local_ops.read_file
            ~workspace_root:runtime.client_config.local_ops.workspace_root
            ~max_bytes:runtime.client_config.local_ops.max_read_bytes path
          |> print_read_result;
          print_blank ();
          loop runtime state
      | Run_command raw_command ->
          print_blank ();
          (match Client_local_ops.parse_exec_words raw_command with
          | Error message -> print_endline message
          | Ok plan -> print_exec_result (run_exec_plan runtime plan));
          print_blank ();
          loop runtime state
      | Run_graph prompt_text ->
          let state =
            run_graph_request runtime state ~request_kind:Graph prompt_text
          in
          loop runtime state
      | Run_discussion prompt_text ->
          let state =
            run_graph_request runtime state ~request_kind:Discussion
              prompt_text
          in
          loop runtime state
      | Run_decide raw_args ->
          (match Client_decide.parse_options raw_args with
           | Error message ->
               print_endline message;
               loop runtime state
           | Ok opts ->
               let rounds =
                 Option.value opts.rounds_override
                   ~default:
                     runtime.Client_runtime.runtime_config.discussion.rounds
               in
               print_blank ();
               Client_ui.print_section "Verifiable Decision"
                 [ Fmt.str "topic:   %s" opts.topic;
                   Fmt.str "rounds:  %d" rounds;
                   Fmt.str "pattern: %s" opts.pattern_id;
                   "";
                   "Running: discussion → L1 consensus → L2 validation → L3 fitness..." ];
               print_blank ();
               (match
                  Lwt_main.run (Client_decide.run runtime opts)
                with
                | Error message ->
                    print_endline message;
                    loop runtime state
                | Ok result ->
                    let consensus_summary =
                      Orchestration_consensus.outcome_summary
                        result.Client_decide.consensus_outcome
                    in
                    let validation_line =
                      match result.Client_decide.validation_payload with
                      | None -> "skipped (no quorum)"
                      | Some p ->
                          if Core_payload.is_error p
                          then Fmt.str "error — %s" (Core_payload.summary p)
                          else Core_payload.summary p
                    in
                    Client_ui.print_section "Decision Result"
                      [ Fmt.str "decision_id:     %s" result.decision_id;
                        Fmt.str "consensus:       %s" consensus_summary;
                        Fmt.str "validation:      %s" validation_line;
                        Fmt.str "fitness:         %.4f"
                          (Core_pattern.fitness
                             result.pattern.Core_pattern.metrics);
                        Fmt.str "audit_verified:  %b"
                          result.audit_verified;
                        Fmt.str "head_hash:       %s"
                          (Core_audit.head_hash result.audit_chain) ];
                    print_blank ();
                    (match Client_decide.write_archive runtime result with
                     | Error message -> print_endline message
                     | Ok path ->
                         Client_ui.print_section
                           ~style:Client_ui.Style.muted
                           "Decision Archive" [ path ]);
                    print_blank ();
                    loop runtime state))
      | Show_docs topic_opt ->
          print_doc_lines runtime
            (Option.value topic_opt ~default:"general operations");
          loop runtime state
      | Run_wizard None ->
          print_blank ();
          Client_ui.print_section_verbatim ~style:Client_ui.Style.muted "Wizard Topics"
            Client_human_constants.Text.wizard_lines;
          print_blank ();
          loop runtime state
      | Run_wizard (Some goal) ->
          let wizard_prompt =
            Fmt.str
              "Guide me through this goal as the human terminal starter \
               wizard: %s"
              goal
          in
          let state =
            run_assistant_request runtime state
              ~request_kind:Client_assistant.Wizard wizard_prompt
          in
          loop runtime state
      | Show_ssh_human ->
          print_blank ();
          Client_ui.print_section "Human SSH"
            [ runtime.client_config.transport.ssh.human_remote_command ];
          print_blank ();
          loop runtime state
      | Show_ssh_machine ->
          print_blank ();
          Client_ui.print_section "Worker SSH"
            [ runtime.client_config.transport.ssh.machine_remote_command ];
          print_blank ();
          loop runtime state
      | Show_http_server ->
          print_blank ();
          Client_ui.print_section "Workflow HTTP Server"
            [
              runtime.client_config.transport.http.workflow.server_command;
              Fmt.str "Advertised base URL: %s"
                runtime.client_config.transport.http.workflow.base_url;
            ];
          print_blank ();
          loop runtime state
      | Show_curl_examples ->
          print_blank ();
          Client_ui.print_section "curl Examples" (http_curl_examples runtime);
          print_blank ();
          loop runtime state
      | Show_install_ssh ->
          print_blank ();
          Client_ui.print_section "SSH Install Bootstrap"
            [ runtime.client_config.transport.ssh.install_emit_command ];
          print_blank ();
          loop runtime state
      | Show_install_http ->
          print_blank ();
          Client_ui.print_section "HTTP Install Bootstrap"
            [
              runtime.client_config.transport.http.distribution.install_url;
              Fmt.str "curl -fsSL %s | sh"
                runtime.client_config.transport.http.distribution.install_url;
            ];
          print_blank ();
          loop runtime state
      | Quit ->
          print_endline Client_human_constants.Text.goodbye;
          0
      | Invalid message ->
          print_endline message;
          loop runtime state
      | Prompt prompt_text ->
          let state =
            run_assistant_request runtime state
              ~request_kind:Client_assistant.Standard prompt_text
          in
          loop runtime state)

let run (runtime : Client_runtime.t) =
  Client_ui.print_banner ~title:Client_human_constants.Text.title
    ~subtitle:
      "Typed orchestration above BulkheadLM with a human lane, a worker lane, \
       SSH remoting, HTTP workflow serving, and bootstrap installers."
    [ "human"; "worker"; "ssh"; "http"; "peer" ];
  Client_ui.print_styled_lines ~style:Client_ui.Style.muted
    Client_human_constants.Text.intro_lines;
  print_blank ();
  Client_ui.print_section ~style:Client_ui.Style.muted "Quick Start"
    [
      "/help for the full deck";
      "/graph ... to execute the typed graph directly";
      "/discussion ... to launch the configured multi-agent discussion workflow";
      "/mesh for SSH, HTTP, install, and peer transport commands";
      "/curl for HTTP workflow examples";
      "/wizard install, /wizard http, or /wizard peer for guided setup";
    ];
  if runtime.Client_runtime.client_config.human_terminal.show_routes_on_start
  then (
    print_blank ();
    Client_ui.print_section ~style:Client_ui.Style.muted "Route Readiness"
      (route_lines runtime));
  print_blank ();
  Client_ui.print_section_verbatim ~style:Client_ui.Style.muted "Doc Shortcuts"
    Client_human_constants.Text.docs_lines;
  print_blank ();
  loop runtime (initial_state runtime)
