(* L0-L3 Verifiable decision session.
   The /decide command wires five swarm layers in sequence for a topic that
   requires a traceable, tamper-evident decision:

     L0   — typed envelope with provenance for the root input and consensus phase
     L0.5 — append-only hash-chained audit log covering every phase transition
     L1   — post-discussion consensus across all three agents (quorum gate)
     L2   — validator pipeline run on the quorum winner
     L3   — pattern fitness recorded per invocation for longitudinal tracking

   Interaction model:
     /decide TOPIC [--rounds N] [--pattern PATTERN_ID]

   Examples:
     /decide Should we adopt Rust for the backend?
     /decide Retire the legacy auth middleware --rounds 8
     /decide Release-gate the memory module --rounds 4 --pattern release-gate-v1
*)

open Lwt.Syntax

(* ------------------------------------------------------------------ *)
(* Options                                                              *)
(* ------------------------------------------------------------------ *)

type options = {
  topic           : string;
  rounds_override : int option;
  pattern_id      : string;
}

let default_pattern_id = "decide-v1"

(* Parse inline options from raw terminal input.
   Syntax: TOPIC [--rounds N] [--pattern ID]
   Options may appear before or after the topic words. *)
let parse_options raw =
  let tokens =
    String.split_on_char ' ' raw
    |> List.filter (fun t -> t <> "")
  in
  let rec loop acc_topic rounds_opt pattern_opt = function
    | [] ->
        let topic = String.concat " " (List.rev acc_topic) in
        if String.trim topic = ""
        then Error "A topic is required for /decide."
        else
          Ok
            { topic;
              rounds_override = rounds_opt;
              pattern_id =
                Option.value pattern_opt ~default:default_pattern_id }
    | "--rounds" :: v :: rest ->
        (match int_of_string_opt v with
         | None  -> Error (Fmt.str "--rounds expects an integer, got: %s" v)
         | Some n when n < 1 -> Error "--rounds must be >= 1."
         | Some n -> loop acc_topic (Some n) pattern_opt rest)
    | "--rounds" :: [] ->
        Error "--rounds requires an integer argument."
    | "--pattern" :: v :: rest ->
        let id = String.trim v in
        if id = ""
        then Error "--pattern requires a non-empty identifier."
        else loop acc_topic rounds_opt (Some id) rest
    | "--pattern" :: [] ->
        Error "--pattern requires a non-empty identifier."
    | token :: rest ->
        loop (token :: acc_topic) rounds_opt pattern_opt rest
  in
  loop [] None None tokens

(* ------------------------------------------------------------------ *)
(* Helpers                                                              *)
(* ------------------------------------------------------------------ *)

let timestamp_now () =
  Unix.gettimeofday ()
  |> Unix.localtime
  |> fun tm ->
    Fmt.str "%04d%02d%02d%02d%02d%02d"
      (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let sanitize_for_id value =
  let buf = Buffer.create (String.length value) in
  String.iter
    (fun c ->
      match c with
      | 'a'..'z' | 'A'..'Z' | '0'..'9' | '-' | '_' ->
          Buffer.add_char buf (Char.lowercase_ascii c)
      | ' ' -> Buffer.add_char buf '-'
      | _ -> ())
    value;
  match Buffer.contents buf with "" -> "decide" | s -> s

(* ------------------------------------------------------------------ *)
(* Result type                                                          *)
(* ------------------------------------------------------------------ *)

type decision_result = {
  decision_id        : string;
  timestamp          : string;
  topic              : string;
  rounds             : int;
  pattern_id         : string;
  discussion_payload : Core_payload.t;
  discussion_context : Core_context.t;
  consensus_outcome  : Orchestration_consensus.outcome;
  validation_payload : Core_payload.t option;
  pattern            : Core_pattern.t;
  audit_chain        : Core_audit.t;
  audit_verified     : bool;
}

(* ------------------------------------------------------------------ *)
(* Runner                                                               *)
(* ------------------------------------------------------------------ *)

let run (runtime : Client_runtime.t) (opts : options) =
  if not runtime.Client_runtime.runtime_config.discussion.enabled
  then
    Lwt.return
      (Error
         "Discussion is disabled. Set discussion.enabled=true in \
          config/runtime.json to use /decide.")
  else
    (* Apply optional rounds override to a config copy. *)
    let config =
      match opts.rounds_override with
      | None -> runtime.Client_runtime.runtime_config
      | Some n ->
          { runtime.runtime_config with
            discussion =
              { runtime.runtime_config.discussion with rounds = n } }
    in
    let ts = timestamp_now () in
    let slug =
      let s = sanitize_for_id opts.topic in
      if String.length s > 32 then String.sub s 0 32 else s
    in
    let decision_id = Fmt.str "decide-%s-%s" ts slug in

    (* L0.5 — open audit chain *)
    let chain =
      Core_audit.empty
      |> Core_audit.append ~label:"decision.started"
           ~detail:
             (Fmt.str "id=%s topic=%s rounds=%d pattern=%s"
                decision_id opts.topic config.discussion.rounds
                opts.pattern_id)
    in

    (* L0 — root envelope carrying the topic *)
    let root_env =
      Core_envelope.make
        ~correlation_id:decision_id
        (Core_payload.Text opts.topic)
    in
    let chain =
      Core_audit.append chain ~label:"decision.envelope.created"
        ~detail:
          (Fmt.str "envelope_id=%s schema=%s"
             root_env.Core_envelope.id
             (Core_envelope.schema_version_string
                root_env.Core_envelope.schema_version))
    in

    (* Phase 1 — Discussion via the existing orchestrator *)
    let services =
      Runtime_services.of_llm_client
        ~config runtime.Client_runtime.llm_client
    in
    let registry = Default_agents.make_registry () in
    let context = Core_context.empty ~task_id:decision_id ~metadata:[] in
    let t0 = Unix.gettimeofday () in
    let* (disc_payload, disc_context) =
      Orchestration_orchestrator.loop
        ~services ~config ~registry
        context (Core_payload.Text opts.topic)
    in
    let disc_ms =
      int_of_float ((Unix.gettimeofday () -. t0) *. 1000.0)
    in
    let chain =
      Core_audit.append chain ~label:"decision.discussion.completed"
        ~detail:
          (Fmt.str "steps=%d latency_ms=%d payload=%s"
             disc_context.Core_context.step_count disc_ms
             (Core_payload.summary disc_payload))
    in

    (* Phase 2 — L1 Consensus: all three agents vote on the discussion output *)
    let agents = Core_agent_name.[ Planner; Summarizer; Validator ] in
    let cons_env = Core_envelope.child_of root_env disc_payload in
    let chain =
      Core_audit.append chain ~label:"decision.consensus.started"
        ~detail:
          (Fmt.str "agents=%d required=%d envelope_id=%s"
             (List.length agents)
             (Orchestration_consensus.required_quorum (List.length agents))
             cons_env.Core_envelope.id)
    in
    let* consensus =
      Orchestration_consensus.run
        ~services ~config ~registry
        ~agents ~context:disc_context ~payload:disc_payload
    in
    let chain =
      Core_audit.append chain ~label:"decision.consensus.completed"
        ~detail:(Orchestration_consensus.outcome_summary consensus)
    in

    (* Phase 3 — L2 Validation pipeline: validate the quorum winner *)
    let* (validation_payload, chain) =
      match consensus with
      | Orchestration_consensus.No_quorum _ ->
          Lwt.return
            ( None,
              Core_audit.append chain
                ~label:"decision.pipeline.skipped"
                ~detail:"reason=no_quorum" )
      | Orchestration_consensus.Quorum_reached { winner; _ } ->
          let pipeline =
            Orchestration_pipeline.(empty |> step Core_agent_name.Validator)
          in
          let* (vp, _) =
            Orchestration_pipeline.run
              ~services ~config ~registry
              ~context:disc_context ~payload:winner
              pipeline
          in
          Lwt.return
            ( Some vp,
              Core_audit.append chain
                ~label:"decision.pipeline.completed"
                ~detail:(Fmt.str "result=%s" (Core_payload.summary vp)) )
    in

    (* Phase 4 — L3 Pattern fitness *)
    let success =
      match validation_payload with
      | Some p -> not (Core_payload.is_error p)
      | None ->
          (match consensus with
           | Orchestration_consensus.Quorum_reached _ -> true
           | Orchestration_consensus.No_quorum _ -> false)
    in
    let total_ms =
      int_of_float ((Unix.gettimeofday () -. t0) *. 1000.0)
    in
    let avg_conf =
      match consensus with
      | Orchestration_consensus.Quorum_reached { total_weight; votes; _ } ->
          total_weight /. float_of_int (max 1 (List.length votes))
      | Orchestration_consensus.No_quorum _ -> 0.0
    in
    let pattern =
      Core_pattern.make
        ~id:opts.pattern_id
        ~stability:Core_pattern.Fluid
        ~description:
          "verifiable decision: discussion → consensus → validation"
      |> Core_pattern.record_outcome
           ~success ~latency_ms:total_ms ~confidence:avg_conf
    in
    let chain =
      Core_audit.append chain ~label:"decision.pattern.recorded"
        ~detail:
          (Fmt.str "pattern_id=%s success=%b fitness=%.4f"
             opts.pattern_id success
             (Core_pattern.fitness pattern.Core_pattern.metrics))
    in

    (* Seal: add final audit entry then verify the full chain *)
    let chain =
      Core_audit.append chain ~label:"decision.sealed"
        ~detail:
          (Fmt.str "chain_length=%d head_hash=%s"
             (Core_audit.length chain)
             (Core_audit.head_hash chain))
    in
    let verified = Core_audit.verify_chain chain in

    Lwt.return
      (Ok
         { decision_id;
           timestamp = ts;
           topic = opts.topic;
           rounds = config.discussion.rounds;
           pattern_id = opts.pattern_id;
           discussion_payload = disc_payload;
           discussion_context = disc_context;
           consensus_outcome = consensus;
           validation_payload;
           pattern;
           audit_chain = chain;
           audit_verified = verified })

(* ------------------------------------------------------------------ *)
(* Archive                                                              *)
(* ------------------------------------------------------------------ *)

let decisions_subdir = Filename.concat "var" "decisions"

let rec ensure_directory path =
  if path = "" || path = "." || Sys.file_exists path then Ok ()
  else
    let parent = Filename.dirname path in
    match ensure_directory parent with
    | Error _ as e -> e
    | Ok () ->
        (try
           Unix.mkdir path 0o755;
           Ok ()
         with
         | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
         | Unix.Unix_error (err, _, _) ->
             Error
               (Fmt.str "Cannot create %s: %s" path
                  (Unix.error_message err)))

let consensus_section_lines = function
  | Orchestration_consensus.No_quorum { required; received; _ } ->
      [ Fmt.str "- outcome: no_quorum";
        Fmt.str "- required: %d" required;
        Fmt.str "- received: %d" received ]
  | Orchestration_consensus.Quorum_reached { votes; total_weight; winner } ->
      [ Fmt.str "- outcome: quorum_reached";
        Fmt.str "- votes: %d" (List.length votes);
        Fmt.str "- total_weight: %.3f" total_weight;
        Fmt.str "- winner: %s" (Core_payload.summary winner) ]

let render_audit_entry (e : Core_audit.entry) =
  Fmt.str "[%02d] %-36s  %s"
    e.Core_audit.sequence e.label
    (String.sub e.self_hash 0 (min 12 (String.length e.self_hash)))

let render_markdown (result : decision_result) =
  let head_hash = Core_audit.head_hash result.audit_chain in
  let validation_line =
    match result.validation_payload with
    | None -> "_skipped — no quorum_"
    | Some p ->
        if Core_payload.is_error p
        then Fmt.str "error — %s" (Core_payload.summary p)
        else Core_payload.summary p
  in
  let audit_lines =
    result.audit_chain |> List.rev |> List.map render_audit_entry
  in
  String.concat "\n"
    ([ "# Decision Archive";
       "";
       Fmt.str "- decision_id: %s" result.decision_id;
       Fmt.str "- archived_at: %s" result.timestamp;
       Fmt.str "- topic: %s" result.topic;
       Fmt.str "- rounds: %d" result.rounds;
       Fmt.str "- pattern_id: %s" result.pattern_id;
       Fmt.str "- audit_chain_length: %d"
         (Core_audit.length result.audit_chain);
       Fmt.str "- audit_verified: %b" result.audit_verified;
       Fmt.str "- head_hash: %s" head_hash;
       "";
       "## Discussion";
       "";
       Fmt.str "- payload: %s"
         (Core_payload.summary result.discussion_payload);
       Fmt.str "- step_count: %d"
         result.discussion_context.Core_context.step_count;
       "";
       "```text";
       Core_payload.to_pretty_string result.discussion_payload;
       "```";
       "";
       "## Consensus (L1)";
       "" ]
    @ consensus_section_lines result.consensus_outcome
    @ [ "";
        "## Validation (L2)";
        "";
        Fmt.str "- result: %s" validation_line;
        "";
        "## Pattern Fitness (L3)";
        "";
        Fmt.str "- pattern_id: %s" result.pattern_id;
        Fmt.str "- invocations: %d"
          result.pattern.Core_pattern.metrics.invocation_count;
        Fmt.str "- success_count: %d"
          result.pattern.Core_pattern.metrics.success_count;
        Fmt.str "- fitness: %.4f"
          (Core_pattern.fitness result.pattern.Core_pattern.metrics);
        "";
        "## Audit Chain (L0.5)";
        "";
        Fmt.str "- verified: %b" result.audit_verified;
        Fmt.str "- head_hash: %s" head_hash;
        "" ]
    @ audit_lines
    @ [ "" ])

let write_archive (runtime : Client_runtime.t) result =
  let dir =
    Filename.concat
      runtime.client_config.local_ops.workspace_root
      decisions_subdir
  in
  match ensure_directory dir with
  | Error _ as e -> e
  | Ok () ->
      let slug =
        let s = sanitize_for_id result.topic in
        if String.length s > 40 then String.sub s 0 40 else s
      in
      let filename =
        Fmt.str "decision-%s-%s.md" result.timestamp slug
      in
      let path = Filename.concat dir filename in
      let content = render_markdown result in
      (try
         Stdlib.Out_channel.with_open_bin path
           (fun ch -> output_string ch content);
         Ok path
       with Sys_error msg ->
         Error
           (Fmt.str "Cannot write decision archive %s: %s" path msg))
