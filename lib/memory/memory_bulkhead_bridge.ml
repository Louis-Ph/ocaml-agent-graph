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
    Cohttp.Header.of_list headers
  in
  let request =
    Cohttp_lwt_unix.Client.call
      `PUT
      ~headers
      ~body:
        (session_json ~session_key:remote_key session
         |> Yojson.Safe.to_string
         |> Cohttp_lwt.Body.of_string)
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
