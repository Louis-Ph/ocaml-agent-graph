type level =
  | Debug
  | Info
  | Warning
  | Error

let level_to_string = function
  | Debug -> "DEBUG"
  | Info -> "INFO"
  | Warning -> "WARN"
  | Error -> "ERROR"

let timestamp () =
  let tm = Unix.localtime (Unix.gettimeofday ()) in
  Fmt.str "%02d:%02d:%02d" tm.tm_hour tm.tm_min tm.tm_sec

let log_entries = ref []

let log level message =
  let entry =
    Fmt.str "[%s] %-5s %s" (timestamp ()) (level_to_string level) message
  in
  log_entries := entry :: !log_entries;
  Fmt.epr "%s\n%!" entry

let collect_logs () =
  let logs = List.rev !log_entries in
  log_entries := [];
  logs

let peek_logs () = List.rev !log_entries

