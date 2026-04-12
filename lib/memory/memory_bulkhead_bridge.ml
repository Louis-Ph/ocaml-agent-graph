open Lwt.Infix

type t = {
  endpoint_uri : Uri.t;
  session_key_prefix : string option;
  authorization : string option;
  timeout_seconds : float;
}

let resolve_authorization
    ~authorization_token_plaintext
    ~authorization_token_env
  =
  match authorization_token_plaintext with
  | Some token when String.trim token <> "" -> Ok (Some ("Bearer " ^ String.trim token))
  | _ ->
      (match authorization_token_env with
       | None -> Ok None
       | Some env_name ->
           (match Sys.getenv_opt env_name with
            | Some token when String.trim token <> "" ->
                Ok (Some ("Bearer " ^ String.trim token))
            | _ ->
                Error
                  (Fmt.str
                     "Memory bulkhead bridge authorization env var is missing or empty: %s"
                     env_name)))

let create (config : Runtime_config.Memory.Bulkhead_bridge.t) =
  match
    resolve_authorization
      ~authorization_token_plaintext:config.authorization_token_plaintext
      ~authorization_token_env:config.authorization_token_env
  with
  | Error _ as error -> error
  | Ok authorization ->
      let endpoint_uri = Uri.of_string config.endpoint_url in
      Ok
        {
          endpoint_uri;
          session_key_prefix = config.session_key_prefix;
          authorization;
          timeout_seconds = config.timeout_seconds;
        }

let role_to_string = function
  | Memory_store.User -> "user"
  | Assistant -> "assistant"

let remote_session_key bridge (session_ref : Memory_store.session_ref) =
  let parts =
    [
      bridge.session_key_prefix;
      Some session_ref.namespace;
      Some session_ref.session_key;
    ]
    |> List.filter_map (function
           | Some value when String.trim value <> "" -> Some (String.trim value)
           | _ -> None)
  in
  String.concat ":" parts

let session_json ~session_key (session : Memory_store.session) =
  `Assoc
    [
      "session_key", `String session_key;
      ( "summary",
        match session.summary with
        | Some summary -> `String summary
        | None -> `Null );
      "compressed_turn_count", `Int session.summarized_turn_count;
      ( "recent_turns",
        `List
          (List.map
             (fun (turn : Memory_store.turn) ->
               `Assoc
                 [
                   "role", `String (role_to_string turn.role);
                   "content", `String turn.content;
                 ])
             session.recent_turns) );
    ]

let response_message response body =
  let status = Cohttp.Response.status response in
  let code = Cohttp.Code.code_of_status status in
  let reason = Cohttp.Code.string_of_status status in
  let trimmed_body = String.trim body in
  if trimmed_body = ""
  then Fmt.str "HTTP %d %s" code reason
  else Fmt.str "HTTP %d %s: %s" code reason trimmed_body

let request_target uri =
  let path = Uri.path uri in
  let path = if path = "" then "/" else path in
  match Uri.verbatim_query uri with
  | None | Some "" -> path
  | Some query -> path ^ "?" ^ query

let host_header uri =
  let host = Uri.host_with_default ~default:"127.0.0.1" uri in
  let port = Uri.port uri in
  match port, Uri.scheme uri with
  | Some 80, Some "http" | Some 443, Some "https" -> host
  | Some value, _ -> Fmt.str "%s:%d" host value
  | None, _ -> host

let split_http_response response_text =
  match String.split_on_char '\n' response_text with
  | [] -> None
  | status_line :: rest ->
      let rec collect_headers acc = function
        | [] -> List.rev acc, []
        | line :: remaining ->
            let trimmed = String.trim line in
            if trimmed = ""
            then List.rev acc, remaining
            else collect_headers (line :: acc) remaining
      in
      let _headers, body_lines = collect_headers [] rest in
      Some (String.trim status_line, String.concat "\n" body_lines |> String.trim)

let parse_status_code status_line =
  match String.split_on_char ' ' status_line with
  | _http_version :: code :: _ -> int_of_string_opt code
  | _ -> None

let http_response_message status_line body =
  match parse_status_code status_line with
  | Some code when String.trim body = "" -> Fmt.str "HTTP %d" code
  | Some code -> Fmt.str "HTTP %d: %s" code (String.trim body)
  | None when String.trim body = "" -> status_line
  | None -> Fmt.str "%s: %s" status_line (String.trim body)

let send_plain_http_put ~uri ~headers ~body =
  let host = Uri.host_with_default ~default:"127.0.0.1" uri in
  let port =
    Uri.port uri
    |> Option.value ~default:80
  in
  Lwt_unix.getaddrinfo
    host
    (string_of_int port)
    [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
  >>= function
  | [] ->
      Lwt.return
        (Error
           (Fmt.str
              "Unable to resolve memory bulkhead bridge host: %s"
              host))
  | first :: _ ->
      Lwt_io.with_connection first.Unix.ai_addr (fun (input_channel, output_channel) ->
          let request_text =
            String.concat
              "\r\n"
              [
                Fmt.str "PUT %s HTTP/1.1" (request_target uri);
                Fmt.str "Host: %s" (host_header uri);
                "Connection: close";
              ]
            ^ "\r\n"
            ^
            (headers
            |> List.map (fun (name, value) -> Fmt.str "%s: %s" name value)
            |> String.concat "\r\n")
            ^ "\r\n"
            ^ Fmt.str "Content-Length: %d" (String.length body)
            ^ "\r\n\r\n"
            ^ body
          in
          Lwt_io.write output_channel request_text >>= fun () ->
          Lwt_io.flush output_channel >>= fun () ->
          Lwt_io.read input_channel >>= fun response_text ->
          match split_http_response response_text with
          | Some (status_line, response_body) ->
              let status_code =
                parse_status_code status_line
                |> Option.value ~default:0
              in
              if status_code >= 200 && status_code < 300
              then Lwt.return (Ok status_code)
              else
                Lwt.return
                  (Error (http_response_message status_line response_body))
          | None ->
              Lwt.return
                (Error "Memory bulkhead bridge returned an empty HTTP response."))

let put_session
    bridge
    (session_ref : Memory_store.session_ref)
    (session : Memory_store.session)
  =
  let remote_key = remote_session_key bridge session_ref in
  let uri =
    Uri.add_query_param'
      bridge.endpoint_uri
      ("session_key", remote_key)
  in
  let headers =
    let headers =
      [ "content-type", "application/json" ]
    in
    let headers =
      match bridge.authorization with
      | Some authorization -> ("authorization", authorization) :: headers
      | None -> headers
    in
    headers
  in
  let body_text =
    session_json ~session_key:remote_key session
    |> Yojson.Safe.to_string
  in
  let request =
    match Uri.scheme uri with
    | Some "http" | None ->
        send_plain_http_put ~uri ~headers ~body:body_text >|= (function
         | Ok status_code ->
             Ok
               (Fmt.str "bulkhead_session=%s status=%d" remote_key status_code)
         | Error _ as error -> error)
    | _ ->
        let headers = Cohttp.Header.of_list headers in
        Cohttp_lwt_unix.Client.call
          `PUT
          ~headers
          ~body:(Cohttp_lwt.Body.of_string body_text)
          uri
        >>= fun (response, body) ->
        Cohttp_lwt.Body.to_string body >|= fun body_text ->
        let status = Cohttp.Response.status response in
        if Cohttp.Code.(is_success (code_of_status status))
        then
          Ok
            (Fmt.str
               "bulkhead_session=%s status=%d"
               remote_key
               (Cohttp.Code.code_of_status status))
        else Error (response_message response body_text)
  in
  let timeout =
    Lwt_unix.sleep bridge.timeout_seconds >|= fun () ->
    Error
      (Fmt.str
         "Memory bulkhead bridge timed out after %.1fs."
         bridge.timeout_seconds)
  in
  Lwt.pick [ request; timeout ]
