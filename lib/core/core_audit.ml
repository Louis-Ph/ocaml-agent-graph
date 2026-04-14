(* L0.5-AUDIT: Append-only, hash-chained audit log.
   Each entry seals its own content and its predecessor's hash so that any
   post-hoc mutation of a past entry breaks every subsequent self_hash.
   Verification replays the chain from genesis and recomputes every hash.

   Hash function: OCaml stdlib Digest (MD5) — collision-resistant enough for
   integrity checking within a single process session.  Replace with
   Digestif.SHA256 when cross-process or storage-backed verification is needed.

   The chain is stored in prepend order (most recent head) so append is O(1)
   and verification reverses once.  Callers that need chronological order
   should call List.rev on the result. *)

let genesis_hash = String.make 32 '0'

(* Compute the self_hash for an entry by hashing the concatenation of its
   defining fields.  The separator '|' prevents field boundary ambiguity. *)
let compute_hash ~previous_hash ~label ~detail ~timestamp =
  let data =
    Printf.sprintf "%s|%s|%s|%.9f" previous_hash label detail timestamp
  in
  Digest.to_hex (Digest.string data)

type entry = {
  sequence      : int;
  label         : string;
  detail        : string;
  timestamp     : float;
  previous_hash : string;
  self_hash     : string;
}

type t = entry list

let empty : t = []

let head_hash : t -> string = function
  | []       -> genesis_hash
  | entry :: _ -> entry.self_hash

let append chain ~label ~detail =
  let timestamp     = Unix.gettimeofday () in
  let sequence      = List.length chain in
  let previous_hash = head_hash chain in
  let self_hash     =
    compute_hash ~previous_hash ~label ~detail ~timestamp
  in
  { sequence; label; detail; timestamp; previous_hash; self_hash } :: chain

(* Verify the chain by replaying from genesis.
   Returns false on the first broken link; true if all hashes are consistent. *)
let verify_chain chain =
  let entries = List.rev chain in
  let rec loop expected_prev = function
    | [] -> true
    | entry :: rest ->
        let recomputed =
          compute_hash
            ~previous_hash:entry.previous_hash
            ~label:entry.label
            ~detail:entry.detail
            ~timestamp:entry.timestamp
        in
        recomputed = entry.self_hash
        && entry.previous_hash = expected_prev
        && loop entry.self_hash rest
  in
  loop genesis_hash entries

let length (chain : t) = List.length chain
