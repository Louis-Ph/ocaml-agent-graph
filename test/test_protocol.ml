(* Tests for L0-PROTOCOL (Envelope, Capability) and L0.5-AUDIT (Audit chain).
   These are pure-function tests — no LLM calls, no Lwt, no mocks. *)

open Agent_graph

(* ------------------------------------------------------------------ *)
(* L0 — Envelope                                                        *)
(* ------------------------------------------------------------------ *)

let test_envelope_unique_ids () =
  let e1 = Core.Envelope.make ~correlation_id:"c1" (Core.Payload.Text "a") in
  let e2 = Core.Envelope.make ~correlation_id:"c1" (Core.Payload.Text "b") in
  Alcotest.(check bool) "ids are unique" true (e1.id <> e2.id)

let test_envelope_preserves_payload () =
  let payload = Core.Payload.Text "hello" in
  let env = Core.Envelope.make ~correlation_id:"c1" payload in
  Alcotest.(check string) "payload summary preserved"
    (Core.Payload.summary payload)
    (Core.Payload.summary env.payload)

let test_envelope_child_inherits_correlation () =
  let parent =
    Core.Envelope.make
      ~correlation_id:"req-abc"
      (Core.Payload.Text "parent")
  in
  let child = Core.Envelope.child_of parent (Core.Payload.Text "child") in
  Alcotest.(check string)
    "child inherits correlation_id"
    "req-abc"
    child.Core.Envelope.correlation_id

let test_envelope_child_causation_points_to_parent () =
  let parent =
    Core.Envelope.make
      ~correlation_id:"req-abc"
      (Core.Payload.Text "parent")
  in
  let child = Core.Envelope.child_of parent (Core.Payload.Text "child") in
  Alcotest.(check (option string))
    "causation_id = parent id"
    (Some parent.Core.Envelope.id)
    child.Core.Envelope.causation_id

let test_envelope_root_has_no_causation () =
  let env = Core.Envelope.make ~correlation_id:"c1" (Core.Payload.Text "x") in
  Alcotest.(check (option string))
    "root envelope has no causation"
    None
    env.Core.Envelope.causation_id

let test_envelope_schema_version_string () =
  let v = Core.Envelope.{ major = 2; minor = 7 } in
  Alcotest.(check string)
    "schema version format"
    "2.7"
    (Core.Envelope.schema_version_string v)

let test_envelope_default_schema_is_v1_0 () =
  let env = Core.Envelope.make ~correlation_id:"c" (Core.Payload.Text "x") in
  Alcotest.(check int) "major=1" 1 env.Core.Envelope.schema_version.major;
  Alcotest.(check int) "minor=0" 0 env.Core.Envelope.schema_version.minor

(* ------------------------------------------------------------------ *)
(* L0 — Capability                                                      *)
(* ------------------------------------------------------------------ *)

let test_capability_observe_permits_only_observe () =
  let tok =
    Core.Capability.grant
      ~agent:Core.Agent_name.Planner
      Core.Capability.Observe
  in
  Alcotest.(check bool) "observe permits observe" true
    (Core.Capability.permits tok Core.Capability.Observe);
  Alcotest.(check bool) "observe does not permit speak" false
    (Core.Capability.permits tok Core.Capability.Speak);
  Alcotest.(check bool) "observe does not permit coordinate" false
    (Core.Capability.permits tok Core.Capability.Coordinate);
  Alcotest.(check bool) "observe does not permit audit_write" false
    (Core.Capability.permits tok Core.Capability.Audit_write)

let test_capability_coordinate_covers_lower_levels () =
  let tok =
    Core.Capability.grant
      ~agent:Core.Agent_name.Summarizer
      Core.Capability.Coordinate
  in
  Alcotest.(check bool) "coordinate permits observe"    true
    (Core.Capability.permits tok Core.Capability.Observe);
  Alcotest.(check bool) "coordinate permits speak"      true
    (Core.Capability.permits tok Core.Capability.Speak);
  Alcotest.(check bool) "coordinate permits coordinate" true
    (Core.Capability.permits tok Core.Capability.Coordinate);
  Alcotest.(check bool) "coordinate does not permit audit_write" false
    (Core.Capability.permits tok Core.Capability.Audit_write)

let test_capability_audit_write_covers_all () =
  let tok =
    Core.Capability.grant
      ~agent:Core.Agent_name.Validator
      Core.Capability.Audit_write
  in
  List.iter
    (fun cap ->
      Alcotest.(check bool)
        (Printf.sprintf "audit_write permits %s" (Core.Capability.to_string cap))
        true
        (Core.Capability.permits tok cap))
    Core.Capability.[ Observe; Speak; Coordinate; Audit_write ]

let test_capability_unexpired_token_is_valid () =
  let tok =
    Core.Capability.grant
      ~expires_in_seconds:3600.0
      ~agent:Core.Agent_name.Planner
      Core.Capability.Speak
  in
  Alcotest.(check bool) "fresh token is valid" true
    (Core.Capability.is_valid tok)

let test_capability_no_expiry_is_always_valid () =
  let tok =
    Core.Capability.grant
      ~agent:Core.Agent_name.Planner
      Core.Capability.Speak
  in
  Alcotest.(check bool) "no-expiry token is valid" true
    (Core.Capability.is_valid tok)

(* ------------------------------------------------------------------ *)
(* L0.5 — Audit chain                                                   *)
(* ------------------------------------------------------------------ *)

let test_audit_empty_chain_verifies () =
  Alcotest.(check bool) "empty chain verifies" true
    (Core.Audit.verify_chain Core.Audit.empty)

let test_audit_empty_chain_length () =
  Alcotest.(check int) "empty chain has length 0" 0
    (Core.Audit.length Core.Audit.empty)

let test_audit_single_entry_verifies () =
  let chain =
    Core.Audit.append Core.Audit.empty ~label:"test.event" ~detail:"x=1"
  in
  Alcotest.(check bool) "single-entry chain verifies" true
    (Core.Audit.verify_chain chain)

let test_audit_multi_entry_verifies () =
  let chain =
    Core.Audit.empty
    |> Core.Audit.append ~label:"discussion.started" ~detail:"rounds=5"
    |> Core.Audit.append ~label:"discussion.turn"    ~detail:"speaker=architect"
    |> Core.Audit.append ~label:"discussion.turn"    ~detail:"speaker=critic"
    |> Core.Audit.append ~label:"discussion.ended"   ~detail:"turns=3"
  in
  Alcotest.(check bool) "four-entry chain verifies" true
    (Core.Audit.verify_chain chain)

let test_audit_length_matches_appended_count () =
  let chain =
    Core.Audit.empty
    |> Core.Audit.append ~label:"a" ~detail:"1"
    |> Core.Audit.append ~label:"b" ~detail:"2"
    |> Core.Audit.append ~label:"c" ~detail:"3"
  in
  Alcotest.(check int) "chain length = 3" 3
    (Core.Audit.length chain)

let test_audit_tampered_detail_breaks_chain () =
  let chain =
    Core.Audit.empty
    |> Core.Audit.append ~label:"a" ~detail:"original"
    |> Core.Audit.append ~label:"b" ~detail:"2"
  in
  (* Tamper the first entry (last in prepend-order list) *)
  let tampered =
    match List.rev chain with
    | entry :: rest ->
        List.rev ({ entry with Core.Audit.detail = "tampered" } :: rest)
    | [] -> chain
  in
  Alcotest.(check bool) "tampered chain fails" false
    (Core.Audit.verify_chain tampered)

let test_audit_tampered_hash_breaks_chain () =
  let chain =
    Core.Audit.empty
    |> Core.Audit.append ~label:"x" ~detail:"y"
  in
  let tampered =
    List.map
      (fun entry -> { entry with Core.Audit.self_hash = "deadbeef" })
      chain
  in
  Alcotest.(check bool) "corrupted self_hash breaks chain" false
    (Core.Audit.verify_chain tampered)

(* ------------------------------------------------------------------ *)
(* L3 — Pattern stability and fitness                                   *)
(* ------------------------------------------------------------------ *)

let test_pattern_zero_fitness_on_empty_metrics () =
  Alcotest.(check (float 1e-9)) "zero fitness for zero invocations" 0.0
    (Core.Pattern.fitness Core.Pattern.zero_metrics)

let test_pattern_fitness_positive_on_success () =
  let m : Core.Pattern.metrics =
    { invocation_count = 10;
      success_count    = 10;
      total_latency_ms = 100;
      total_confidence = 9.0;
    }
  in
  Alcotest.(check bool) "fitness > 0 for successful pattern" true
    (Core.Pattern.fitness m > 0.0)

let test_pattern_fitness_higher_success_wins () =
  let make sc : Core.Pattern.metrics =
    { invocation_count = 10; success_count = sc;
      total_latency_ms = 200; total_confidence = 7.0 }
  in
  let good = make 9 in
  let bad  = make 2 in
  Alcotest.(check bool) "higher success_count → higher fitness" true
    (Core.Pattern.fitness good > Core.Pattern.fitness bad)

let test_pattern_fitness_lower_latency_wins () =
  let make lms : Core.Pattern.metrics =
    { invocation_count = 10; success_count = 10;
      total_latency_ms = lms; total_confidence = 8.0 }
  in
  let fast = make 10 in
  let slow = make 5000 in
  Alcotest.(check bool) "lower latency → higher fitness" true
    (Core.Pattern.fitness fast > Core.Pattern.fitness slow)

let test_pattern_stability_frozen_cannot_mutate () =
  Alcotest.(check bool) "Frozen cannot accept any mutation" false
    (Core.Pattern.can_mutate ~current:Core.Pattern.Frozen ~proposed:Core.Pattern.Volatile)

let test_pattern_stability_volatile_accepts_all () =
  List.iter
    (fun proposed ->
      Alcotest.(check bool)
        (Printf.sprintf "Volatile accepts %s" (Core.Pattern.stability_to_string proposed))
        true
        (Core.Pattern.can_mutate ~current:Core.Pattern.Volatile ~proposed))
    Core.Pattern.[ Frozen; Stable; Fluid; Volatile ]

let test_pattern_record_outcome_increments_count () =
  let p = Core.Pattern.make ~id:"p1" ~stability:Core.Pattern.Fluid ~description:"test" in
  let p1 = Core.Pattern.record_outcome p ~success:true ~latency_ms:10 ~confidence:0.9 in
  Alcotest.(check int) "invocation_count = 1" 1 p1.Core.Pattern.metrics.invocation_count;
  Alcotest.(check int) "success_count = 1"    1 p1.Core.Pattern.metrics.success_count

let test_pattern_record_failure_does_not_increment_success () =
  let p = Core.Pattern.make ~id:"p1" ~stability:Core.Pattern.Fluid ~description:"test" in
  let p1 = Core.Pattern.record_outcome p ~success:false ~latency_ms:5 ~confidence:0.5 in
  Alcotest.(check int) "success_count stays 0 on failure" 0
    p1.Core.Pattern.metrics.success_count

(* ------------------------------------------------------------------ *)
(* Runner                                                               *)
(* ------------------------------------------------------------------ *)

let () =
  let open Alcotest in
  run "protocol-and-audit"
    [
      ( "L0-envelope",
        [
          test_case "unique ids"                     `Quick test_envelope_unique_ids;
          test_case "preserves payload"              `Quick test_envelope_preserves_payload;
          test_case "child inherits correlation"     `Quick test_envelope_child_inherits_correlation;
          test_case "child causation = parent id"    `Quick test_envelope_child_causation_points_to_parent;
          test_case "root has no causation"          `Quick test_envelope_root_has_no_causation;
          test_case "schema_version_string format"   `Quick test_envelope_schema_version_string;
          test_case "default schema is 1.0"          `Quick test_envelope_default_schema_is_v1_0;
        ] );
      ( "L0-capability",
        [
          test_case "observe permits only observe"      `Quick test_capability_observe_permits_only_observe;
          test_case "coordinate covers lower levels"    `Quick test_capability_coordinate_covers_lower_levels;
          test_case "audit_write covers all"            `Quick test_capability_audit_write_covers_all;
          test_case "unexpired token is valid"          `Quick test_capability_unexpired_token_is_valid;
          test_case "no-expiry token is always valid"   `Quick test_capability_no_expiry_is_always_valid;
        ] );
      ( "L0.5-audit",
        [
          test_case "empty chain verifies"              `Quick test_audit_empty_chain_verifies;
          test_case "empty chain length = 0"            `Quick test_audit_empty_chain_length;
          test_case "single entry verifies"             `Quick test_audit_single_entry_verifies;
          test_case "multi entry verifies"              `Quick test_audit_multi_entry_verifies;
          test_case "length matches append count"       `Quick test_audit_length_matches_appended_count;
          test_case "tampered detail breaks chain"      `Quick test_audit_tampered_detail_breaks_chain;
          test_case "corrupted self_hash breaks chain"  `Quick test_audit_tampered_hash_breaks_chain;
        ] );
      ( "L3-pattern",
        [
          test_case "zero fitness on empty metrics"            `Quick test_pattern_zero_fitness_on_empty_metrics;
          test_case "fitness positive on success"              `Quick test_pattern_fitness_positive_on_success;
          test_case "higher success → higher fitness"          `Quick test_pattern_fitness_higher_success_wins;
          test_case "lower latency → higher fitness"           `Quick test_pattern_fitness_lower_latency_wins;
          test_case "frozen cannot mutate"                     `Quick test_pattern_stability_frozen_cannot_mutate;
          test_case "volatile accepts all stability proposals" `Quick test_pattern_stability_volatile_accepts_all;
          test_case "record_outcome increments count"          `Quick test_pattern_record_outcome_increments_count;
          test_case "failure does not increment success"       `Quick test_pattern_record_failure_does_not_increment_success;
        ] );
    ]
