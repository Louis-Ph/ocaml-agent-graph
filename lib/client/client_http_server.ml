open Lwt.Infix

let json_headers = Cohttp.Header.of_list [ "content-type", "application/json" ]

let respond_json ?(status = `OK) json =
  Cohttp_lwt_unix.Server.respond_string
    ~status
    ~headers:json_headers
    ~body:(Yojson.Safe.to_string json)
    ()

let respond_error ?(status = `Bad_request) message =
  respond_json ~status (`Assoc [ "ok", `Bool false; "error", `String message ])

let health_json (runtime : Client_runtime.t) =
  `Assoc
    [
      "ok", `Bool true;
      "assistant_route_model", `String runtime.client_config.assistant.route_model;
      "worker_jobs", `Int runtime.client_config.machine_terminal.worker_jobs;
      "http_workflow_base_url", `String runtime.client_config.transport.http.workflow.base_url;
    ]

let capabilities_json (runtime : Client_runtime.t) =
  `Assoc
    [
      "ok", `Bool true;
      "call_kinds",
      `List
        [
          `String (Client_machine.call_kind_to_string Client_machine.Assistant);
          `String (Client_machine.call_kind_to_string Client_machine.Inspect_graph);
          `String (Client_machine.call_kind_to_string Client_machine.Run_graph);
        ];
      "graph_summary", Client_runtime.graph_summary_to_yojson runtime;
    ]

let request_kind_of_uri uri =
  match Uri.get_query_param uri "kind" with
  | None -> Ok Client_machine.Assistant
  | Some raw_kind -> Client_machine.call_kind_of_string raw_kind

let invoke_request runtime ~kind body =
  try
    let json = Yojson.Safe.from_string body in
    Client_machine.invoke_json runtime ~kind json
    >|= Result.map Client_machine.call_response_to_yojson
  with
  | Yojson.Json_error message ->
      Lwt.return (Error (Fmt.str "Invalid JSON request body: %s" message))

let callback runtime _conn req body =
  let method_ = Cohttp.Request.meth req in
  let uri = Cohttp.Request.uri req in
  let path = Uri.path uri in
  match method_, path with
  | `GET, "/health" -> respond_json (health_json runtime)
  | `GET, "/v1/capabilities" -> respond_json (capabilities_json runtime)
  | `POST, "/v1/assistant" ->
      Cohttp_lwt.Body.to_string body >>= invoke_request runtime ~kind:Client_machine.Assistant
      >>= (function
            | Ok json -> respond_json json
            | Error message -> respond_error message)
  | `POST, "/v1/inspect_graph" ->
      Cohttp_lwt.Body.to_string body
      >>= invoke_request runtime ~kind:Client_machine.Inspect_graph
      >>= (function
            | Ok json -> respond_json json
            | Error message -> respond_error message)
  | `POST, "/v1/run_graph" ->
      Cohttp_lwt.Body.to_string body >>= invoke_request runtime ~kind:Client_machine.Run_graph
      >>= (function
            | Ok json -> respond_json json
            | Error message -> respond_error message)
  | `POST, "/v1/call" ->
      (match request_kind_of_uri uri with
       | Error message -> respond_error message
       | Ok kind ->
           Cohttp_lwt.Body.to_string body >>= invoke_request runtime ~kind
           >>= (function
                 | Ok json -> respond_json json
                 | Error message -> respond_error message))
  | _ ->
      respond_error
        ~status:`Not_found
        (Fmt.str "Unknown workflow endpoint: %s %s" (Cohttp.Code.string_of_method method_) path)

let run ~port runtime =
  let server = Cohttp_lwt_unix.Server.make ~callback:(callback runtime) () in
  print_endline
    (Fmt.str
       "ocaml-agent-graph workflow HTTP server listening on http://0.0.0.0:%d"
       port);
  Lwt_main.run (Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port port)) server)
