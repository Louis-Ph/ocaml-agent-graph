open Lwt.Syntax

type options = {
  topic : string;
  generations_override : int option;
  width_override : int option;
  pattern_id : string option;
}

type run_result = {
  timestamp : string;
  pattern_id : string;
  swarm : Orchestration_napoleon_swarm.result;
  runtime_logs : string list;
}

let timestamp_now () =
  Unix.gettimeofday () |> Unix.localtime |> fun tm ->
  Fmt.str "%04d%02d%02d%02d%02d%02d" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec

let parse_positive_int ~option_name value =
  match int_of_string_opt value with
  | None -> Error (Fmt.str "%s expects an integer, got: %s" option_name value)
  | Some n when n < 1 -> Error (Fmt.str "%s must be >= 1." option_name)
  | Some n -> Ok n

let parse_options raw =
  let tokens =
    String.split_on_char ' ' raw |> List.filter (fun token -> token <> "")
  in
  let rec loop acc_topic generations width pattern = function
    | [] ->
        let topic = String.concat " " (List.rev acc_topic) in
        if String.trim topic = "" then
          Error "A topic is required for /napoleon."
        else
          Ok
            {
              topic;
              generations_override = generations;
              width_override = width;
              pattern_id = pattern;
            }
    | ("--generations" | "--gens") :: value :: rest -> (
        match parse_positive_int ~option_name:"--generations" value with
        | Error _ as error -> error
        | Ok n -> loop acc_topic (Some n) width pattern rest)
    | ("--generations" | "--gens") :: [] ->
        Error "--generations requires an integer argument."
    | "--width" :: value :: rest -> (
        match parse_positive_int ~option_name:"--width" value with
        | Error _ as error -> error
        | Ok n -> loop acc_topic generations (Some n) pattern rest)
    | "--width" :: [] -> Error "--width requires an integer argument."
    | "--pattern" :: value :: rest ->
        let value = String.trim value in
        if value = "" then Error "--pattern requires a non-empty identifier."
        else loop acc_topic generations width (Some value) rest
    | "--pattern" :: [] -> Error "--pattern requires a non-empty identifier."
    | token :: rest -> loop (token :: acc_topic) generations width pattern rest
  in
  loop [] None None None tokens

let run (runtime : Client_runtime.t) (opts : options) =
  let napoleon = runtime.Client_runtime.runtime_config.napoleon in
  if not napoleon.enabled then
    Lwt.return
      (Error
         "Napoleon swarm is disabled. Set napoleon_swarm.enabled=true in \
          config/runtime.json, then retry.")
  else
    let generations =
      Option.value opts.generations_override ~default:napoleon.generations
    in
    let width = Option.value opts.width_override ~default:napoleon.width in
    let pattern_id =
      Option.value opts.pattern_id ~default:napoleon.pattern_id
    in
    let config =
      {
        runtime.runtime_config with
        napoleon = { napoleon with generations; width; pattern_id };
      }
    in
    let () = ignore (Runtime_logger.collect_logs ()) in
    let services =
      Runtime_services.of_llm_client ~config runtime.Client_runtime.llm_client
    in
    let registry = Default_agents.make_registry () in
    let context =
      Core_context.empty
        ~task_id:(Fmt.str "napoleon-terminal-%s" (timestamp_now ()))
        ~metadata:[]
    in
    let* result =
      Orchestration_napoleon_swarm.run ~services ~config ~registry context
        ~topic:opts.topic ~pattern_id ~generations ~width
    in
    let runtime_logs = Runtime_logger.collect_logs () in
    Lwt.return
      (Result.map
         (fun swarm ->
           { timestamp = timestamp_now (); pattern_id; swarm; runtime_logs })
         result)

let sanitize_filename_component value =
  let buffer = Buffer.create (String.length value) in
  String.iter
    (fun character ->
      match character with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' ->
          Buffer.add_char buffer (Char.lowercase_ascii character)
      | _ -> Buffer.add_char buffer '-')
    value;
  match Buffer.contents buffer with "" -> "napoleon" | rendered -> rendered

let rec ensure_directory path =
  if path = "" || path = "." || Sys.file_exists path then Ok ()
  else
    let parent = Filename.dirname path in
    match ensure_directory parent with
    | Error _ as error -> error
    | Ok () -> (
        try
          Unix.mkdir path 0o755;
          Ok ()
        with
        | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
        | Unix.Unix_error (error, _, _) ->
            Error
              (Fmt.str "Cannot create archive directory %s: %s" path
                 (Unix.error_message error)))

let archive_dir (runtime : Client_runtime.t) =
  let subdir = runtime.runtime_config.napoleon.archive_subdir in
  if Filename.is_relative subdir then
    Filename.concat runtime.client_config.local_ops.workspace_root subdir
  else subdir

let filename result =
  Fmt.str "napoleon-%s-%s.md" result.timestamp
    (sanitize_filename_component result.swarm.run_id)

let render_audit_entry (entry : Core_audit.entry) =
  Fmt.str "[%02d] %-34s %s" entry.Core_audit.sequence entry.label
    (String.sub entry.self_hash 0 (min 12 (String.length entry.self_hash)))

let render_role_output (output : Orchestration_napoleon_swarm.role_output) =
  [
    Fmt.str "### %s" output.role_name;
    "";
    Fmt.str "- kind: %s"
      (Runtime_config.Napoleon.Role_kind.to_string output.role_kind);
    Fmt.str "- generation: %s"
      (match output.generation_index with
      | None -> "final"
      | Some index -> string_of_int index);
    Fmt.str "- success: %b" output.success;
    Fmt.str "- confidence: %.3f" output.metrics.confidence;
    Fmt.str "- latency_ms: %d" output.latency_ms;
    "";
    "```text";
    output.content;
    "```";
    "";
  ]

let render_generation
    (generation : Orchestration_napoleon_swarm.generation_result) =
  [ Fmt.str "## Generation %d" generation.index; ""; "### Candidates"; "" ]
  @ (generation.candidates |> List.map render_role_output |> List.flatten)
  @ [ "### Reserve Arbitration"; "" ]
  @ render_role_output generation.reserve
  @ [ "### Evolved Frontier"; ""; "```text"; generation.frontier; "```"; "" ]

let render_markdown result =
  let swarm = result.swarm in
  let audit_lines =
    swarm.audit_chain |> List.rev |> List.map render_audit_entry
  in
  String.concat "\n"
    ([
       "# Napoleon Swarm Archive";
       "";
       Fmt.str "- archived_at: %s" result.timestamp;
       Fmt.str "- run_id: %s" swarm.run_id;
       Fmt.str "- topic: %s" swarm.topic;
       Fmt.str "- generations: %d" swarm.generation_count;
       Fmt.str "- width: %d" swarm.width;
       Fmt.str "- pattern_id: %s" result.pattern_id;
       Fmt.str "- fitness: %.4f"
         (Core_pattern.fitness swarm.pattern.Core_pattern.metrics);
       Fmt.str "- audit_verified: %b" swarm.audit_verified;
       Fmt.str "- total_latency_ms: %d" swarm.total_latency_ms;
       "";
       "## Plan";
       "";
       "```text";
       swarm.plan
       |> List.mapi (fun index step -> Fmt.str "%d. %s" (index + 1) step)
       |> String.concat "\n";
       "```";
       "";
     ]
    @ (swarm.generations |> List.map render_generation |> List.flatten)
    @ [ "## Final Output"; "" ]
    @ render_role_output swarm.final
    @ [
        "## Final Payload";
        "";
        "```text";
        Core_payload.to_pretty_string swarm.final_payload;
        "```";
        "";
        "## Execution Events";
        "";
      ]
    @ (match List.rev swarm.context.Core_context.events with
      | [] -> [ "_no orchestration event recorded_" ]
      | events ->
          events
          |> List.map (fun (event : Core_context.event) ->
                 Fmt.str "%02d  %s  %s" event.step_index event.label
                   event.detail))
    @ [ ""; "## Audit Chain"; "" ]
    @ audit_lines
    @ [ ""; "## Runtime Logs"; "" ]
    @ (if result.runtime_logs = [] then [ "_no runtime logs collected_" ]
       else result.runtime_logs)
    @ [ "" ])

let write_archive (runtime : Client_runtime.t) result =
  let archive_dir = archive_dir runtime in
  match ensure_directory archive_dir with
  | Error _ as error -> error
  | Ok () -> (
      let archive_path = Filename.concat archive_dir (filename result) in
      try
        Stdlib.Out_channel.with_open_bin archive_path (fun channel ->
            output_string channel (render_markdown result));
        Ok archive_path
      with Sys_error message ->
        Error
          (Fmt.str "Cannot write napoleon archive %s: %s" archive_path message))
