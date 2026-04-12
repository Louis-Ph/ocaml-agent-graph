open Lwt.Infix
open Lwt.Syntax

type t = {
  policy : Runtime_config.Memory.t;
  store : Memory_store.t;
  bulkhead_bridge : Memory_bulkhead_bridge.t option;
}

let session_key_of_context
    (policy : Runtime_config.Memory.t)
    (context : Core_context.t)
  =
  match policy.session_id_metadata_key with
  | Some metadata_key ->
      (match List.assoc_opt metadata_key context.metadata with
      | Some value when String.trim value <> "" -> String.trim value
      | _ -> context.task_id)
  | None -> context.task_id

let session_ref runtime context =
  {
    Memory_store.namespace = runtime.policy.session_namespace;
    session_key = session_key_of_context runtime.policy context;
  }

let default_sqlite_path (llm_client : Llm_bulkhead_client.t) =
  llm_client.store.Bulkhead_lm.Runtime_state.config.persistence.sqlite_path

let create (config : Runtime_config.t) (llm_client : Llm_bulkhead_client.t) =
  if not config.memory.enabled
  then Ok None
  else
    let sqlite_path =
      match config.memory.storage.mode with
      | Runtime_config.Memory.Storage.Bulkhead_gateway_sqlite ->
          default_sqlite_path llm_client
      | Explicit_sqlite -> config.memory.storage.sqlite_path
    in
    match sqlite_path with
    | Some path when String.trim path <> "" ->
        (match
           Memory_store.open_store path,
           (match config.memory.bulkhead_bridge with
            | None -> Ok None
            | Some bridge ->
                Memory_bulkhead_bridge.create bridge
                |> Result.map Option.some)
         with
         | Ok store, Ok bulkhead_bridge ->
             Ok (Some { policy = config.memory; store; bulkhead_bridge })
         | (Error _ as error), _ -> error
         | _, (Error _ as error) -> error)
    | _ ->
        Error
          "Memory policy is enabled, but no SQLite path is available. Configure an explicit memory sqlite_path or enable BulkheadLM persistence."

let durable_summary_message summary =
  {
    Core_message.role = Core_message.System;
    content = "Persistent memory summary:\n" ^ summary;
  }

let history_message_of_turn (turn : Memory_store.turn) =
  {
    Core_message.role =
      (match turn.role with
      | Memory_store.User -> User
      | Assistant -> Core_message.Assistant);
    content = turn.content;
  }

let record_message_if_non_empty context role content =
  match String.trim content with
  | "" -> context
  | trimmed -> Core_context.add_message context { Core_message.role = role; content = trimmed }

let hydrate runtime context =
  let session =
    Memory_store.load_session
      runtime.store
      (session_ref runtime context)
      ~recent_turn_buffer:runtime.policy.reload.recent_turn_buffer
  in
  let context =
    match session.summary with
    | None -> context
    | Some summary ->
        Core_context.add_message context (durable_summary_message summary)
  in
  let context =
    session.recent_turns
    |> List.map history_message_of_turn
    |> List.fold_left Core_context.add_message context
  in
  context

let prepare_context runtime context payload =
  let hydrated = hydrate runtime context in
  record_message_if_non_empty
    hydrated
    Core_message.User
    (Core_payload.to_pretty_string payload)

let persist_exchange
    runtime
    ~(llm_client : Llm_bulkhead_client.t)
    ~(llm_config : Runtime_config.Llm.t)
    context
    ~input_payload
    ~result_payload
  =
  let session_ref = session_ref runtime context in
  let user_content = Core_payload.to_pretty_string input_payload in
  let assistant_content = Core_payload.to_pretty_string result_payload in
  let session =
    Memory_store.append_exchange
      runtime.store
      session_ref
      ~recent_turn_buffer:runtime.policy.reload.recent_turn_buffer
      ~user_content
      ~assistant_content
  in
  let archive_before_turn =
    max
      session.summarized_turn_count
      (session.turn_count - runtime.policy.reload.recent_turn_buffer)
  in
  let* compressed_session =
    if
      Memory_compressor.should_compress
        runtime.policy.compression
        ~reply_count:session.reply_count
      && archive_before_turn > session.summarized_turn_count
    then
      let archived_turns =
        Memory_store.load_turns_range
          runtime.store
          session_ref
          ~first_turn_index:session.summarized_turn_count
          ~past_last_turn_index:archive_before_turn
      in
      let level =
        Memory_compressor.next_level session.compression_count
      in
      let* summary =
        Memory_compressor.compress_history
          ~llm_client
          ~profile:llm_config.summarizer
          ~compression:runtime.policy.compression
          ~existing_summary:session.summary
          ~turns:archived_turns
          ~level
      in
      let updated =
        Memory_store.update_summary
          runtime.store
          session_ref
          ~recent_turn_buffer:runtime.policy.reload.recent_turn_buffer
          ~summary:(Some summary)
          ~compression_count:(session.compression_count + 1)
          ~summarized_turn_count:archive_before_turn
      in
      Lwt.return updated
    else Lwt.return session
  in
  let detail =
    Fmt.str
      "session=%s replies=%d compressed=%d recent_turns=%d"
      session_ref.session_key
      compressed_session.reply_count
      compressed_session.compression_count
      (List.length compressed_session.recent_turns)
  in
  let context =
    Core_context.record_event context ~label:"memory.persisted" ~detail
  in
  match runtime.bulkhead_bridge with
  | None -> Lwt.return context
  | Some bulkhead_bridge ->
      Memory_bulkhead_bridge.put_session
        bulkhead_bridge
        session_ref
        compressed_session
      >|= (function
       | Ok bridge_detail ->
           Core_context.record_event
             context
             ~label:"memory.bulkhead_synced"
             ~detail:bridge_detail
       | Error message ->
           Core_context.record_event
             context
             ~label:"memory.bulkhead_sync_failed"
             ~detail:message)
