open Lwt.Infix

type compression_level =
  | Fib of int

let role_label = function
  | Memory_store.User -> "user"
  | Assistant -> "assistant"

let percentage_of_level = function
  | Fib index ->
      let divisor = Int.shift_left 1 (max 0 index) in
      max 1 (100 / divisor)

let next_level compression_count = Fib (compression_count + 1)

let should_compress
    (compression : Runtime_config.Memory.Compression.t)
    ~reply_count
  =
  List.mem reply_count compression.reply_checkpoints
  ||
  match List.rev compression.reply_checkpoints with
  | [] -> false
  | last_checkpoint :: _ when reply_count > last_checkpoint ->
      let interval = max 1 compression.continue_every_replies in
      (reply_count - last_checkpoint) mod interval = 0
  | _ -> false

let trim_summary max_chars text =
  let trimmed = String.trim text in
  if max_chars <= 0 || String.length trimmed <= max_chars
  then trimmed
  else String.sub trimmed 0 (max_chars - 3) ^ "..."

let turn_line (turn : Memory_store.turn) =
  Fmt.str "%d. [%s] %s" turn.turn_index (role_label turn.role) turn.content

let fallback_summary
    ~(summary_max_chars : int)
    ~(existing_summary : string option)
    ~(turns : Memory_store.turn list)
  =
  let blocks =
    [
      Option.map
        (fun summary -> "Existing durable summary:\n" ^ summary)
        existing_summary;
      Some
        ("New conversation turns:\n"
        ^ (turns |> List.map turn_line |> String.concat "\n"));
    ]
    |> List.filter_map Fun.id
  in
  trim_summary summary_max_chars (String.concat "\n\n" blocks)

let compression_prompt
    ~(prompt : string)
    ~(existing_summary : string option)
    ~(turns : Memory_store.turn list)
    ~(level : compression_level)
  =
  Fmt.str
    "%s\n\nCompression target: about %d%% of the original length.\n\nExisting durable \
     summary:\n%s\n\nNew conversation turns to absorb:\n%s\n\nReturn one compact memory \
     note with stable facts, goals, constraints, names, preferences, decisions, and \
     unresolved items."
    prompt
    (percentage_of_level level)
    (Option.value existing_summary ~default:"(none)")
    (turns |> List.map turn_line |> String.concat "\n")

let compress_history
    ~(llm_client : Llm_bulkhead_client.t)
    ~(profile : Runtime_config.Llm.Agent_profile.t)
    ~(compression : Runtime_config.Memory.Compression.t)
    ~(existing_summary : string option)
    ~(turns : Memory_store.turn list)
    ~(level : compression_level)
  =
  match turns with
  | [] ->
      Lwt.return (Option.value existing_summary ~default:"")
  | _ ->
      let messages : Bulkhead_lm.Openai_types.message list =
        [
          { role = "system"; content = profile.system_prompt };
          {
            role = "user";
            content =
              compression_prompt
                ~prompt:compression.summary_prompt
                ~existing_summary
                ~turns
                ~level;
          };
        ]
      in
      Llm_bulkhead_client.invoke_messages
        llm_client
        ~route_model:profile.route_model
        ~messages
        ~max_tokens:
          (match compression.summary_max_tokens with
          | Some _ as value -> value
          | None -> profile.max_tokens)
      >|= function
      | Ok completion ->
          let summary =
            match String.trim completion.content with
            | "" ->
                fallback_summary
                  ~summary_max_chars:compression.summary_max_chars
                  ~existing_summary
                  ~turns
            | value -> trim_summary compression.summary_max_chars value
          in
          summary
      | Error _ ->
          fallback_summary
            ~summary_max_chars:compression.summary_max_chars
            ~existing_summary
            ~turns
