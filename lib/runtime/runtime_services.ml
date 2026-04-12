type t = {
  config : Runtime_config.t;
  llm_client : Llm_bulkhead_client.t;
  memory_runtime : Memory_runtime.t option;
}

let validate_discussion_bindings
    (llm_client : Llm_bulkhead_client.t)
    (config : Runtime_config.t)
  =
  if not config.discussion.enabled
  then Ok ()
  else
    match
      Llm_bulkhead_client.validate_route_models
        llm_client
        (Runtime_config.Discussion.route_models config.discussion)
    with
    | Ok () -> Ok ()
    | Error message ->
        Error
          (Fmt.str
             "Invalid BulkheadLM binding for discussion workflow: %s"
             message)

let create config =
  match Llm_bulkhead_client.create config.Runtime_config.llm with
  | Error _ as error -> error
  | Ok llm_client ->
      (match
         Llm_bulkhead_client.validate_agent_profiles
           llm_client
           config.Runtime_config.llm
       with
       | Error _ as error -> error
       | Ok () ->
           (match validate_discussion_bindings llm_client config with
            | Error _ as error -> error
            | Ok () ->
                (match Memory_runtime.create config llm_client with
                 | Error _ as error -> error
                 | Ok memory_runtime -> Ok { config; llm_client; memory_runtime })))

let of_llm_client ~config llm_client =
  (match
     Llm_bulkhead_client.validate_agent_profiles llm_client config.Runtime_config.llm
   with
   | Ok () -> ()
   | Error message -> failwith message);
  (match validate_discussion_bindings llm_client config with
   | Ok () -> ()
   | Error message -> failwith message);
  let memory_runtime =
    match Memory_runtime.create config llm_client with
    | Ok value -> value
    | Error message -> failwith message
  in
  { config; llm_client; memory_runtime }
