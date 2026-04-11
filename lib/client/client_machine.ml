open Lwt.Infix

type call_kind =
  | Assistant
  | Inspect_graph
  | Run_graph
  | Messenger_spokesperson

type call_response =
  | Assistant_response of Client_assistant.reply
  | Graph_summary_response of Yojson.Safe.t
  | Run_graph_response of Yojson.Safe.t
  | Messenger_spokesperson_response of Yojson.Safe.t

type worker_request = {
  line_no : int;
  id : string option;
  kind : call_kind;
  request_json : Yojson.Safe.t;
}

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_member_opt name json =
  match member name json with
  | Some (`String value) when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let string_list_member name json =
  match member name json with
  | Some (`List values) ->
      Ok
        (values
         |> List.filter_map (function
                | `String value when String.trim value <> "" -> Some (String.trim value)
                | _ -> None))
  | Some _ -> Error (Fmt.str "Invalid %s list." name)
  | None -> Ok []

let bool_member_with_default name json ~default =
  match member name json with
  | Some (`Bool value) -> value
  | _ -> default

let call_kind_to_string = function
  | Assistant -> "assistant"
  | Inspect_graph -> "inspect_graph"
  | Run_graph -> "run_graph"
  | Messenger_spokesperson -> "messenger_spokesperson"

let call_kind_of_string = function
  | "assistant" -> Ok Assistant
  | "inspect_graph" -> Ok Inspect_graph
  | "run_graph" -> Ok Run_graph
  | "messenger_spokesperson" -> Ok Messenger_spokesperson
  | value ->
      Error
        (Fmt.str
           "Unsupported client kind: %s. Expected one of assistant, inspect_graph, run_graph, messenger_spokesperson."
           value)

let call_response_to_yojson = function
  | Assistant_response reply -> Client_assistant.reply_to_yojson reply
  | Graph_summary_response json -> json
  | Run_graph_response json -> json
  | Messenger_spokesperson_response json -> json

let response_text = function
  | Assistant_response reply -> reply.message
  | Graph_summary_response json -> Yojson.Safe.pretty_to_string json
  | Run_graph_response json -> Yojson.Safe.pretty_to_string json
  | Messenger_spokesperson_response json -> Yojson.Safe.pretty_to_string json

let load_attachments (runtime : Client_runtime.t) paths =
  let open Client_local_ops in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | path :: rest ->
        (match
           read_file
             ~workspace_root:runtime.Client_runtime.client_config.local_ops.workspace_root
             ~max_bytes:runtime.client_config.local_ops.max_read_bytes
             path
         with
         | Ok attachment -> loop (attachment :: acc) rest
         | Error message ->
             Error (Fmt.str "Unable to attach %s: %s" path message))
  in
  loop [] paths

let event_to_yojson (event : Core_context.event) =
  `Assoc
    [
      "step_index", `Int event.step_index;
      "label", `String event.label;
      "detail", `String event.detail;
      "timestamp", `Float event.timestamp;
    ]

let run_graph_json (runtime : Client_runtime.t) task_id input =
  match Runtime_services.create runtime.Client_runtime.runtime_config with
  | Error _ as error -> Lwt.return error
  | Ok services ->
      let registry = Default_agents.make_registry () in
      let context = Core_context.empty ~task_id ~metadata:[] in
      (Orchestration_orchestrator.loop
         ~services
         ~config:runtime.runtime_config
         ~registry
         context
         (Core_payload.Text input))
      >|= function
      | payload, context ->
          Ok
            (`Assoc
               [
                 "task_id", `String context.task_id;
                 "payload_summary", `String (Core_payload.summary payload);
                 "payload_pretty", `String (Core_payload.to_pretty_string payload);
                 ( "completed_agents",
                   `List
                     (Core_context.completed_agent_names context
                      |> List.map (fun value -> `String value)) );
                 "step_count", `Int context.step_count;
                 "events", `List (List.rev context.events |> List.map event_to_yojson);
               ])

let assistant_request (runtime : Client_runtime.t) json =
  let prompt =
    match string_member_opt "prompt" json with
    | Some value -> Ok value
    | None -> Error "Assistant requests require a non-empty prompt."
  in
  match prompt with
  | Error _ as error -> Lwt.return error
  | Ok prompt ->
      let route_model =
        Option.value
          (string_member_opt "route_model" json)
          ~default:runtime.Client_runtime.client_config.assistant.route_model
      in
      let attachments =
        match string_list_member "attachments" json with
        | Error _ as error -> error
        | Ok paths -> load_attachments runtime paths
      in
      (match attachments with
       | Error _ as error -> Lwt.return error
       | Ok attachments ->
           Client_assistant.ask
             runtime
             ~route_model
             ~conversation:[]
             ~attachments
             prompt)

let inspect_graph_json (runtime : Client_runtime.t) json =
  let _include_routes = bool_member_with_default "include_routes" json ~default:true in
  Ok (Client_runtime.graph_summary_to_yojson runtime)

let invoke_json (runtime : Client_runtime.t) ~kind json =
  match kind with
  | Assistant ->
      assistant_request runtime json
      >|= Result.map (fun reply -> Assistant_response reply)
  | Inspect_graph ->
      Lwt.return
        (inspect_graph_json runtime json
         |> Result.map (fun graph -> Graph_summary_response graph))
  | Run_graph ->
      (match string_member_opt "input" json with
       | None -> Lwt.return (Error "run_graph requests require a non-empty input.")
       | Some input ->
           let task_id =
             Option.value
               (string_member_opt "task_id" json)
               ~default:runtime.runtime_config.demo.task_id
           in
           run_graph_json runtime task_id input
           >|= Result.map (fun value -> Run_graph_response value))
  | Messenger_spokesperson ->
      (match Bulkhead_lm.Openai_types.chat_request_of_yojson json with
       | Error field ->
           Lwt.return
             (Error
                (Fmt.str
                   "messenger_spokesperson requests require a valid OpenAI chat request field: %s"
                   field))
       | Ok request ->
           Client_messenger_spokesperson.respond runtime request
           >|= Result.map (fun response ->
                  Messenger_spokesperson_response
                    (Bulkhead_lm.Openai_types.chat_response_to_yojson response)))

let request_kind_json kind = `String (call_kind_to_string kind)

let success_json ~id ~kind ~line_no response =
  `Assoc
    [
      "ok", `Bool true;
      "id", `String id;
      "kind", request_kind_json kind;
      "line", `Int line_no;
      "response", call_response_to_yojson response;
    ]

let error_json ?id ?kind ?line_no message =
  let fields =
    [
      Some ("ok", `Bool false);
      Some ("error", `String message);
      Option.map (fun value -> "id", `String value) id;
      Option.map (fun value -> "kind", request_kind_json value) kind;
      Option.map (fun value -> "line", `Int value) line_no;
    ]
    |> List.filter_map Fun.id
  in
  `Assoc fields

let parse_worker_request ~line_no line =
  try
    let json = Yojson.Safe.from_string line in
    let kind =
      match string_member_opt "kind" json with
      | None -> Ok Assistant
      | Some value -> call_kind_of_string value
    in
    match kind with
    | Error message -> Error (string_member_opt "id" json, None, message)
    | Ok kind ->
        (match member "request" json with
         | Some request_json ->
             Ok
               {
                 line_no;
                 id = string_member_opt "id" json;
                 kind;
                 request_json;
               }
         | None ->
             Error
               ( string_member_opt "id" json,
                 Some kind,
                 Fmt.str "Worker line %d is missing the request object." line_no ))
  with
  | Yojson.Json_error message ->
      Error
        (None, None, Fmt.str "Worker line %d is not valid JSON: %s" line_no message)

let worker_count jobs = max 1 jobs

type 'a shared_queue = {
  items : 'a Queue.t;
  lock : Lwt_mutex.t;
  available : unit Lwt_condition.t;
  mutable closed : bool;
}

let create_shared_queue () =
  {
    items = Queue.create ();
    lock = Lwt_mutex.create ();
    available = Lwt_condition.create ();
    closed = false;
  }

let push_queue queue item =
  Lwt_mutex.with_lock queue.lock (fun () ->
      Queue.push item queue.items;
      Lwt_condition.broadcast queue.available ();
      Lwt.return_unit)

let close_queue queue =
  Lwt_mutex.with_lock queue.lock (fun () ->
      queue.closed <- true;
      Lwt_condition.broadcast queue.available ();
      Lwt.return_unit)

let rec pop_queue queue =
  Lwt_mutex.with_lock queue.lock (fun () ->
      if not (Queue.is_empty queue.items) then Lwt.return (`Item (Queue.pop queue.items))
      else if queue.closed then Lwt.return `Closed
      else Lwt_condition.wait ~mutex:queue.lock queue.available >|= fun () -> `Retry)
  >>= function
  | `Item item -> Lwt.return_some item
  | `Closed -> Lwt.return_none
  | `Retry -> pop_queue queue

let rec worker_loop queue emit handle =
  pop_queue queue
  >>= function
  | None -> Lwt.return_unit
  | Some item ->
      handle item >>= emit >>= fun () -> worker_loop queue emit handle

let run_lines runtime ~jobs lines =
  let queue = create_shared_queue () in
  let outputs = ref [] in
  let output_lock = Lwt_mutex.create () in
  let emit json =
    Lwt_mutex.with_lock output_lock (fun () ->
        outputs := Yojson.Safe.to_string json :: !outputs;
        Lwt.return_unit)
  in
  let handle (line_no, line) =
    match parse_worker_request ~line_no line with
    | Ok request ->
        invoke_json runtime ~kind:request.kind request.request_json
        >|= (function
         | Ok response ->
             let id =
               match request.id with
               | Some value -> value
               | None -> Fmt.str "line-%d" request.line_no
             in
             success_json ~id ~kind:request.kind ~line_no:request.line_no response
         | Error message ->
             error_json
               ?id:request.id
               ~kind:request.kind
               ~line_no:request.line_no
               message)
    | Error (id, kind, message) ->
        Lwt.return (error_json ?id ?kind ~line_no message)
  in
  List.iteri
    (fun index line -> Queue.push (index + 1, line) queue.items)
    lines;
  queue.closed <- true;
  let workers =
    List.init (worker_count jobs) (fun _ -> worker_loop queue emit handle)
  in
  Lwt.join workers >|= fun () -> List.rev !outputs

let run_stdio runtime ~jobs () =
  let queue = create_shared_queue () in
  let output_lock = Lwt_mutex.create () in
  let emit json =
    Lwt_mutex.with_lock output_lock (fun () ->
        Lwt_io.write_line Lwt_io.stdout (Yojson.Safe.to_string json))
  in
  let handle (line_no, line) =
    match parse_worker_request ~line_no line with
    | Ok request ->
        invoke_json runtime ~kind:request.kind request.request_json
        >|= (function
         | Ok response ->
             let id =
               match request.id with
               | Some value -> value
               | None -> Fmt.str "line-%d" request.line_no
             in
             success_json ~id ~kind:request.kind ~line_no:request.line_no response
         | Error message ->
             error_json
               ?id:request.id
               ~kind:request.kind
               ~line_no:request.line_no
               message)
    | Error (id, kind, message) ->
        Lwt.return (error_json ?id ?kind ~line_no message)
  in
  let rec read_loop line_no =
    Lwt_io.read_line_opt Lwt_io.stdin
    >>= function
    | None ->
        close_queue queue
    | Some line ->
        push_queue queue (line_no, line) >>= fun () -> read_loop (line_no + 1)
  in
  let workers =
    List.init (worker_count jobs) (fun _ -> worker_loop queue emit handle)
  in
  Lwt.join [ read_loop 1; Lwt.join workers ]
