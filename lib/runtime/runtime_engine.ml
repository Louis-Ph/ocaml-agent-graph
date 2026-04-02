open Lwt.Syntax

let with_timeout timeout_seconds promise =
  Lwt.pick
    [
      promise;
      (let* () = Lwt_unix.sleep timeout_seconds in
       Lwt.fail_with "agent timeout");
    ]

let measure_latency_ms started_at =
  let elapsed = Unix.gettimeofday () -. started_at in
  int_of_float (elapsed *. 1000.0)

let build_item ~agent ~payload ~metrics ~notes =
  { Core_payload.agent; payload; metrics; notes }

let failure_item agent message =
  build_item
    ~agent
    ~payload:(Core_payload.Error message)
    ~metrics:Core_payload.zero_metrics
    ~notes:[ message ]

let run_agent ~(config : Runtime_config.t) ~registry agent context payload =
  match Runtime_registry.find registry agent with
  | None ->
      let message =
        Fmt.str "Unknown agent: %s" (Core_agent_name.to_string agent)
      in
      Runtime_logger.log Runtime_logger.Error message;
      Lwt.return (failure_item agent message)
  | Some (module Agent : Agent_intf.S) ->
      let started_at = Unix.gettimeofday () in
      let retry_policy =
        {
          Runtime_retry_policy.max_retries = config.engine.retry_attempts;
          backoff_seconds = config.engine.retry_backoff_seconds;
        }
      in
      Runtime_logger.log
        Runtime_logger.Info
        (Fmt.str
           "Running %s on %s"
           (Core_agent_name.to_string agent)
           (Core_payload.summary payload));
      Lwt.catch
        (fun () ->
          let* output, metrics, notes =
            Runtime_retry_policy.run retry_policy (fun () ->
                with_timeout config.engine.timeout_seconds
                  (Agent.run context payload))
          in
          let latency_ms = measure_latency_ms started_at in
          let measured_metrics = { metrics with latency_ms } in
          Lwt.return
            (build_item ~agent ~payload:output ~metrics:measured_metrics ~notes))
        (fun exn ->
          let message =
            Fmt.str
              "Agent %s failed: %s"
              (Core_agent_name.to_string agent)
              (Printexc.to_string exn)
          in
          Runtime_logger.log Runtime_logger.Error message;
          Lwt.return (failure_item agent message))
