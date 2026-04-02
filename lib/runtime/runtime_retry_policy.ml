open Lwt.Syntax

type t = {
  max_retries : int;
  backoff_seconds : float;
}

let run policy fn =
  let rec attempt retry_index =
    Lwt.catch
      fn
      (fun exn ->
        if retry_index >= policy.max_retries then Lwt.fail exn
        else
          let* () = Lwt_unix.sleep policy.backoff_seconds in
          attempt (retry_index + 1))
  in
  attempt 0

