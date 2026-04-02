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

let log level message =
  Fmt.epr "[%s] %-5s %s\n%!" (timestamp ()) (level_to_string level) message

