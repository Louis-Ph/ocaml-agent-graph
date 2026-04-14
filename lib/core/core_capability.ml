(* L0-PROTOCOL: Capability token lattice for agent access control.
   Permissions form a total order: Observe ⊑ Speak ⊑ Coordinate ⊑ Audit_write.
   An agent holds the minimal capability sufficient for its role; the runtime
   refuses operations that exceed the granted level.

   Tokens carry an optional expiry so transient delegation can be time-bounded.
   The lattice is intentionally flat (4 levels) — additional granularity should
   be expressed as separate token dimensions rather than a deeper chain. *)

type t =
  | Observe     (** read-only: inspect context and payload *)
  | Speak       (** produce a turn or output message *)
  | Coordinate  (** route or delegate work to other agents *)
  | Audit_write (** append entries to the audit log *)

type token = {
  capability : t;
  agent      : Core_agent_name.t;
  granted_at : float;
  expires_at : float option;
}

let rank = function
  | Observe     -> 0
  | Speak       -> 1
  | Coordinate  -> 2
  | Audit_write -> 3

(* A token permits an operation when its rank covers the required level. *)
let permits token required = rank token.capability >= rank required

let is_valid token =
  match token.expires_at with
  | None   -> true
  | Some t -> Unix.gettimeofday () < t

let grant ?(expires_in_seconds : float option) ~agent capability =
  {
    capability;
    agent;
    granted_at = Unix.gettimeofday ();
    expires_at = Option.map (fun s -> Unix.gettimeofday () +. s) expires_in_seconds;
  }

let to_string = function
  | Observe     -> "observe"
  | Speak       -> "speak"
  | Coordinate  -> "coordinate"
  | Audit_write -> "audit_write"
