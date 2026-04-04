open Lwt.Infix

type command = {
  command : string;
  args : string list;
  cwd : string option;
  why : string option;
}

type reply = {
  message : string;
  commands : command list;
  raw_content : string;
  route_model : string;
  resolved_model : string;
  usage : Llm_aegis_client.usage;
  route_access_summary : string;
}

type attachment = Client_local_ops.read_file_result

type request_kind =
  | Standard
  | Wizard

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let non_empty_string = function
  | `String value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let unwrap_markdown_code_block content =
  let trimmed = String.trim content in
  if not (String.starts_with ~prefix:"```" trimmed) then None
  else
    match String.index_opt trimmed '\n' with
    | None -> None
    | Some first_newline ->
        let remainder =
          String.sub
            trimmed
            (first_newline + 1)
            (String.length trimmed - first_newline - 1)
          |> String.trim
        in
        if String.ends_with ~suffix:"```" remainder then
          Some
            (String.sub remainder 0 (String.length remainder - 3)
            |> String.trim)
        else None

let parse_json_object content =
  try
    match Yojson.Safe.from_string content with
    | `Assoc _ as json -> Some json
    | _ -> None
  with
  | _ -> None

let command_of_yojson json =
  match member "command" json with
  | Some (`String command) when String.trim command <> "" ->
      let args =
        match member "args" json with
        | Some (`List values) ->
            values
            |> List.filter_map (function
                   | `String value -> Some value
                   | _ -> None)
        | _ -> []
      in
      let cwd =
        match member "cwd" json with
        | Some (`String value) when String.trim value <> "" -> Some (String.trim value)
        | _ -> None
      in
      let why =
        match member "why" json with
        | Some (`String value) when String.trim value <> "" -> Some (String.trim value)
        | _ -> None
      in
      Some { command = String.trim command; args; cwd; why }
  | _ -> None

let reply_body_of_content content =
  let trimmed = String.trim content in
  let json =
    match parse_json_object trimmed with
    | Some json -> Some json
    | None -> (
        match unwrap_markdown_code_block trimmed with
        | Some unfenced -> parse_json_object unfenced
        | None -> None)
  in
  match json with
  | Some json ->
      let message =
        match member "message" json |> Option.value ~default:`Null |> non_empty_string with
        | Some value -> value
        | None -> trimmed
      in
      let commands =
        match member "commands" json with
        | Some (`List values) -> values |> List.filter_map command_of_yojson
        | _ -> []
      in
      message, commands
  | None -> trimmed, []

let command_to_yojson command =
  `Assoc
    [
      "command", `String command.command;
      "args", `List (List.map (fun value -> `String value) command.args);
      ( "cwd",
        match command.cwd with
        | Some value -> `String value
        | None -> `Null );
      ( "why",
        match command.why with
        | Some value -> `String value
        | None -> `Null );
    ]

let reply_to_yojson reply =
  `Assoc
    [
      "message", `String reply.message;
      "commands", `List (List.map command_to_yojson reply.commands);
      "raw_content", `String reply.raw_content;
      "route_model", `String reply.route_model;
      "resolved_model", `String reply.resolved_model;
      ( "usage",
        `Assoc
          [
            "prompt_tokens", `Int reply.usage.prompt_tokens;
            "completion_tokens", `Int reply.usage.completion_tokens;
            "total_tokens", `Int reply.usage.total_tokens;
          ] );
      "route_access", `String reply.route_access_summary;
    ]

let trim_turns ~keep_turns messages =
  let keep_messages = max 0 (keep_turns * 2) in
  let rec take_last count items =
    let length = List.length items in
    if length <= count then items
    else take_last count (List.tl items)
  in
  if keep_messages = 0 then [] else take_last keep_messages messages

let render_attachment (attachment : attachment) =
  let truncation =
    if attachment.truncated then "\n[truncated-for-chat]" else ""
  in
  Fmt.str
    "File: %s\nBytes read: %d%s\n---\n%s"
    attachment.path
    attachment.bytes_read
    truncation
    attachment.content

let render_attachments attachments =
  match attachments with
  | [] -> "none"
  | _ -> attachments |> List.map render_attachment |> String.concat "\n\n"

let request_kind_label = function
  | Standard -> "normal assistance request"
  | Wizard -> "starter wizard request"

let request_instructions = function
  | Standard ->
      "Expected behavior:\n- answer concretely\n- relate the request to the graph and provider structure\n- propose next steps when useful"
  | Wizard ->
      "Expected behavior:\n- behave like a proactive starter wizard\n- explain a step-by-step plan for build, test, install, cron, ssh, or swarm work\n- propose safe local commands when they would move the user forward"

let user_prompt ?(request_kind = Standard) ~runtime ~attachments prompt =
  let documentation_context =
    Client_assistant_docs.render_prompt_context runtime ~goal:prompt
  in
  Fmt.str
    "Request kind:\n%s\n\n%s\n\nGraph summary:\n%s\n\nAttached files:\n%s\n\nDocumentation briefing:\n%s\n\nUser request:\n%s"
    (request_kind_label request_kind)
    (request_instructions request_kind)
    (Client_runtime.graph_summary_text runtime)
    (render_attachments attachments)
    documentation_context
    prompt

let ask
    runtime
    ?(request_kind = Standard)
    ~route_model
    ~conversation
    ~attachments
    prompt
  =
  let config = runtime.Client_runtime.client_config in
  let messages =
    let system_message : Aegis_lm.Openai_types.message =
      {
        role = "system";
        content = config.assistant.system_prompt;
      }
    in
    let conversation =
      trim_turns
        ~keep_turns:config.human_terminal.conversation_keep_turns
        conversation
    in
    let user_message : Aegis_lm.Openai_types.message =
      {
        role = "user";
        content = user_prompt ~request_kind ~runtime ~attachments prompt;
      }
    in
    system_message :: conversation @ [ user_message ]
  in
  Llm_aegis_client.invoke_messages
    runtime.llm_client
    ~route_model
    ~messages
    ~max_tokens:config.assistant.max_tokens
  >|= function
  | Error _ as error -> error
  | Ok completion ->
      let message, commands = reply_body_of_content completion.content in
      Ok
        {
          message;
          commands;
          raw_content = completion.content;
          route_model = completion.route_model;
          resolved_model = completion.model;
          usage = completion.usage;
          route_access_summary =
            Llm_aegis_client.route_access_summary completion.route_access;
        }
