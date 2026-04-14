(* L0-PROTOCOL: Typed message envelope with provenance metadata.
   Every payload exchanged between agents is wrapped in an envelope that
   carries a correlation_id (traces a logical request end-to-end),
   a causation_id (the id of the envelope that triggered this one), and a
   schema_version so consumers can reject incompatible shapes before
   deserializing.

   Envelope identifiers are monotonic-timestamp + random suffix to be both
   sortable and collision-resistant within a single process. *)

type schema_version = {
  major : int;
  minor : int;
}

let v1_0 : schema_version = { major = 1; minor = 0 }

type t = {
  id             : string;
  correlation_id : string;
  causation_id   : string option;
  schema_version : schema_version;
  payload        : Core_payload.t;
  emitted_at     : float;
}

let generate_id () =
  let ts_ms = int_of_float (Unix.gettimeofday () *. 1000.0) in
  let rand  = Random.bits () land 0xFFFFFF in
  Printf.sprintf "%d-%06x" ts_ms rand

let make
    ?(schema_version = v1_0)
    ?causation_id
    ~correlation_id
    payload
  =
  {
    id = generate_id ();
    correlation_id;
    causation_id;
    schema_version;
    payload;
    emitted_at = Unix.gettimeofday ();
  }

(* Derive a child envelope that shares the parent's correlation_id and
   records the parent as its direct cause. *)
let child_of parent payload =
  {
    id             = generate_id ();
    correlation_id = parent.correlation_id;
    causation_id   = Some parent.id;
    schema_version = parent.schema_version;
    payload;
    emitted_at     = Unix.gettimeofday ();
  }

let schema_version_string v = Printf.sprintf "%d.%d" v.major v.minor

let summary envelope =
  Printf.sprintf
    "id=%s corr=%s schema=%s payload=%s"
    envelope.id
    envelope.correlation_id
    (schema_version_string envelope.schema_version)
    (Core_payload.summary envelope.payload)
