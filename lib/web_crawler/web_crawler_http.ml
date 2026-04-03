open Lwt.Syntax

let measure_timeout timeout_seconds promise =
  Lwt.pick
    [
      promise;
      (let* () = Lwt_unix.sleep timeout_seconds in
       Lwt.fail_with "http timeout");
    ]

let run_curl ~timeout_seconds arguments =
  let argv = Array.of_list ("curl" :: arguments) in
  let process =
    Lwt_process.open_process_full ("curl", argv)
  in
  let stdout_promise = Lwt_io.read process#stdout in
  let stderr_promise = Lwt_io.read process#stderr in
  let read_all =
    let* stdout = stdout_promise
    and* stderr = stderr_promise in
    let* status = process#status in
    Lwt.return (stdout, stderr, status)
  in
  Lwt.catch
    (fun () ->
      let* stdout, stderr, status =
        measure_timeout timeout_seconds read_all
      in
      match status with
      | Unix.WEXITED 0 -> Lwt.return (Ok stdout)
      | Unix.WEXITED code ->
          Lwt.return
            (Error
               (Fmt.str
                  "curl exited with code %d: %s"
                  code
                  (String.trim stderr)))
      | Unix.WSIGNALED signal
      | Unix.WSTOPPED signal ->
          Lwt.return
            (Error
               (Fmt.str
                  "curl terminated by signal %d: %s"
                  signal
                  (String.trim stderr))))
    (fun exn ->
      process#terminate;
      Lwt.return (Error (Printexc.to_string exn)))

let fetch_text ~user_agent ~timeout_seconds url =
  run_curl
    ~timeout_seconds
    [ "-L"; "-sS"; "--compressed"; "-A"; user_agent; url ]
