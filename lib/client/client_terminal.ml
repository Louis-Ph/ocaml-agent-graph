type state = {
  active_route_model : string;
  conversation : Aegis_lm.Openai_types.message list;
  attachments : Client_assistant.attachment list;
}

type command =
  | Empty
  | Help
  | Tools
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
  | Show_docs of string option
  | Run_wizard of string option
  | Show_ssh_human
  | Show_ssh_machine
  | Quit
  | Prompt of string
  | Invalid of string

let commands = Client_human_constants.commands

let print_lines lines = List.iter print_endline lines
let print_blank () = print_endline ""

let parse_command input =
  let trimmed = String.trim input in
  let starts prefix =
    String.starts_with ~prefix:(prefix ^ " ") trimmed
  in
  let tail prefix =
    let offset = String.length prefix + 1 in
    String.sub trimmed offset (String.length trimmed - offset) |> String.trim
  in
  if trimmed = "" then Empty
  else if trimmed = Client_human_constants.Command.help then Help
  else if trimmed = Client_human_constants.Command.tools then Tools
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
  else if trimmed = Client_human_constants.Command.ssh_machine then Show_ssh_machine
  else if trimmed = Client_human_constants.Command.quit then Quit
  else if trimmed = Client_human_constants.Command.swap then Invalid "/swap expects a route model."
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
    if command = "" then Invalid "/run expects a command." else Run_command command
  else Prompt trimmed

let initial_state (runtime : Client_runtime.t) =
  {
    active_route_model = runtime.Client_runtime.client_config.assistant.route_model;
    conversation = [];
    attachments = [];
  }

let update_terminal_context (runtime : Client_runtime.t) =
  Aegis_lm.Starter_terminal.set_context
    ~commands
    ~models:(Llm_aegis_client.route_models runtime.Client_runtime.llm_client)

let help_lines current_route_model =
  Client_human_constants.Text.command_help_lines current_route_model

let route_lines (runtime : Client_runtime.t) =
  let route_models = Llm_aegis_client.route_models runtime.Client_runtime.llm_client in
  match route_models with
  | [] -> [ "No AegisLM routes are configured." ]
  | _ ->
      route_models
      |> List.map (fun route_model ->
             match Llm_aegis_client.route_access runtime.llm_client ~route_model with
             | Some route_access -> Llm_aegis_client.route_access_summary route_access
             | None -> Fmt.str "route_model=%s unavailable" route_model)

let trim_conversation (runtime : Client_runtime.t) conversation =
  let keep =
    runtime.Client_runtime.client_config.human_terminal.conversation_keep_turns * 2
  in
  let rec drop count items =
    if List.length items <= count then items else drop count (List.tl items)
  in
  if keep <= 0 then [] else drop keep conversation

let attachment_line (attachment : Client_assistant.attachment) =
  Fmt.str
    "- %s (%d bytes%s)"
    attachment.path
    attachment.bytes_read
    (if attachment.truncated then ", truncated" else "")

let prompt_for_command_execution (command : Client_assistant.command) =
  let command_line =
    match command.args with
    | [] -> command.command
    | args -> String.concat " " (command.command :: args)
  in
  (match command.why with
   | Some why -> print_endline (Fmt.str "Suggested command: %s\nWhy: %s" command_line why)
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
       ~workspace_root:runtime.Client_runtime.client_config.local_ops.workspace_root
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
  print_lines (Client_assistant_docs.doc_overview_lines runtime ~goal);
  print_blank ()

let run_assistant_request runtime state ~request_kind prompt_text =
  let attachments = List.rev state.attachments in
  let conversation = trim_conversation runtime state.conversation in
  match
    Lwt_main.run
      (Client_assistant.ask
         runtime
         ~request_kind
         ~route_model:state.active_route_model
         ~conversation
         ~attachments
         prompt_text)
  with
  | Error message ->
      print_endline message;
      { state with attachments = [] }
  | Ok reply ->
      print_blank ();
      print_endline reply.message;
      print_endline
        (Fmt.str
           "route=%s model=%s tokens=%d"
           reply.route_model
           reply.resolved_model
           reply.usage.total_tokens);
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
            { Aegis_lm.Openai_types.role = "user"; content = prompt_text };
            { role = "assistant"; content = reply.message };
          ]
      in
      { state with attachments = []; conversation }

let rec loop (runtime : Client_runtime.t) state =
  update_terminal_context runtime;
  let prompt = Fmt.str "%s> " state.active_route_model in
  match Aegis_lm.Starter_terminal.read_line ~record_history:true ~prompt () with
  | None -> 0
  | Some input ->
      (match parse_command input with
       | Empty -> loop runtime state
       | Help ->
           print_blank ();
           print_lines (help_lines state.active_route_model);
           print_blank ();
           loop runtime state
       | Tools ->
           print_blank ();
           print_lines Client_human_constants.Text.tool_lines;
           print_blank ();
           loop runtime state
       | Inspect ->
           print_blank ();
           print_endline (Client_runtime.graph_summary_text runtime);
           print_blank ();
           loop runtime state
       | Show_config ->
           print_blank ();
           print_lines
             [
               Fmt.str "client_config: %s" runtime.client_config_path;
               Fmt.str "graph_runtime_config: %s" runtime.runtime_config_path;
               Fmt.str
                 "workspace_root: %s"
                 runtime.client_config.local_ops.workspace_root;
               Fmt.str "assistant_route_model: %s" state.active_route_model;
             ];
           print_blank ();
           loop runtime state
       | Show_models ->
           print_blank ();
           print_lines (route_lines runtime);
           print_blank ();
           loop runtime state
       | Swap_model route_model ->
           (match
              Llm_aegis_client.route_access runtime.llm_client ~route_model
            with
           | Some _ ->
               print_endline (Client_human_constants.Text.route_switched route_model);
               loop runtime { state with active_route_model = route_model }
           | None ->
               print_endline (Client_human_constants.Text.unknown_route route_model);
               loop runtime state)
       | Attach_file path ->
           (match
              Client_local_ops.read_file
                ~workspace_root:runtime.client_config.local_ops.workspace_root
                ~max_bytes:runtime.client_config.local_ops.max_read_bytes
                path
            with
           | Ok attachment ->
               print_endline (Client_human_constants.Text.file_attached attachment.path);
               loop runtime { state with attachments = attachment :: state.attachments }
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
             ~workspace_root:runtime.client_config.local_ops.workspace_root
             path
           |> print_list_result;
           print_blank ();
           loop runtime state
       | Open_path path ->
           print_blank ();
           Client_local_ops.read_file
             ~workspace_root:runtime.client_config.local_ops.workspace_root
             ~max_bytes:runtime.client_config.local_ops.max_read_bytes
             path
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
       | Show_docs topic_opt ->
           print_doc_lines runtime (Option.value topic_opt ~default:"general operations");
           loop runtime state
       | Run_wizard None ->
           print_blank ();
           print_lines Client_human_constants.Text.wizard_lines;
           print_blank ();
           loop runtime state
       | Run_wizard (Some goal) ->
           let wizard_prompt =
             Fmt.str
               "Guide me through this goal as the human terminal starter wizard: %s"
               goal
           in
           let state =
             run_assistant_request
               runtime
               state
               ~request_kind:Client_assistant.Wizard
               wizard_prompt
           in
           loop runtime state
       | Show_ssh_human ->
           print_blank ();
           print_endline runtime.client_config.ssh.human_remote_command;
           print_blank ();
           loop runtime state
       | Show_ssh_machine ->
           print_blank ();
           print_endline runtime.client_config.ssh.machine_remote_command;
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
             run_assistant_request
               runtime
               state
               ~request_kind:Client_assistant.Standard
               prompt_text
           in
           loop runtime state)

let run (runtime : Client_runtime.t) =
  print_endline Client_human_constants.Text.title;
  print_lines Client_human_constants.Text.intro_lines;
  if runtime.Client_runtime.client_config.human_terminal.show_routes_on_start then (
    print_blank ();
    print_lines (route_lines runtime);
    print_blank ());
  print_lines (help_lines runtime.client_config.assistant.route_model);
  print_blank ();
  print_lines Client_human_constants.Text.docs_lines;
  print_blank ();
  loop runtime (initial_state runtime)
