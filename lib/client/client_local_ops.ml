open Lwt.Infix

type dir_entry_kind =
  | File
  | Directory
  | Symlink
  | Other

type dir_entry = {
  name : string;
  kind : dir_entry_kind;
  size_bytes : int option;
}

type list_dir_result = {
  path : string;
  entries : dir_entry list;
}

type read_file_result = {
  path : string;
  content : string;
  bytes_read : int;
  truncated : bool;
}

type exec_plan = {
  command : string;
  args : string list;
  cwd : string option;
}

type exec_result = {
  command : string;
  args : string list;
  cwd : string;
  exit_code : int;
  stdout : string;
  stderr : string;
  truncated : bool;
}

let normalize_absolute_path path =
  let absolute =
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path
  in
  let rec loop acc = function
    | [] -> List.rev acc
    | "" :: rest
    | "." :: rest -> loop acc rest
    | ".." :: rest ->
        (match acc with
         | _ :: tail -> loop tail rest
         | [] -> loop [] rest)
    | segment :: rest -> loop (segment :: acc) rest
  in
  match loop [] (String.split_on_char '/' absolute) with
  | [] -> "/"
  | segments -> "/" ^ String.concat "/" segments

let existing_realpath path =
  try Ok (Unix.realpath path) with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
      Error (Fmt.str "Path was not found: %s" path)
  | Unix.Unix_error (err, _, _) ->
      Error (Fmt.str "Unable to resolve path %s: %s" path (Unix.error_message err))

let ensure_directory path =
  try
    let stats = Unix.stat path in
    if stats.Unix.st_kind = Unix.S_DIR then Ok ()
    else Error (Fmt.str "Expected a directory but received: %s" path)
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
      Error (Fmt.str "Path was not found: %s" path)
  | Unix.Unix_error (err, _, _) ->
      Error (Fmt.str "Unable to inspect directory %s: %s" path (Unix.error_message err))

let ensure_regular_file path =
  try
    let stats = Unix.stat path in
    if stats.Unix.st_kind = Unix.S_REG then Ok stats
    else Error (Fmt.str "Expected a regular file but received: %s" path)
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
      Error (Fmt.str "Path was not found: %s" path)
  | Unix.Unix_error (err, _, _) ->
      Error (Fmt.str "Unable to inspect file %s: %s" path (Unix.error_message err))

let has_root_prefix ~root path =
  if root = "/" then true
  else
    let prefix = root ^ "/" in
    path = root || String.starts_with ~prefix path

let ensure_under_root ~workspace_root path =
  if has_root_prefix ~root:workspace_root path then Ok ()
  else
    Error
      (Fmt.str
         "Path is outside the configured workspace root %s: %s"
         workspace_root
         path)

let resolve_workspace_root raw_root =
  let normalized = normalize_absolute_path raw_root in
  match existing_realpath normalized with
  | Error _ as error -> error
  | Ok path -> ensure_directory path |> Result.map (fun () -> path)

let resolve_path ~workspace_root raw_path =
  let candidate =
    if Filename.is_relative raw_path then Filename.concat workspace_root raw_path else raw_path
  in
  let normalized = normalize_absolute_path candidate in
  match existing_realpath normalized with
  | Error _ as error -> error
  | Ok path -> ensure_under_root ~workspace_root path |> Result.map (fun () -> path)

let dir_entry_kind_of_stats stats =
  match stats.Unix.st_kind with
  | Unix.S_REG -> File
  | Unix.S_DIR -> Directory
  | Unix.S_LNK -> Symlink
  | _ -> Other

let list_dir ~workspace_root raw_path =
  match resolve_workspace_root workspace_root with
  | Error _ as error -> error
  | Ok workspace_root -> (
      match resolve_path ~workspace_root raw_path with
      | Error _ as error -> error
      | Ok path -> (
          match ensure_directory path with
          | Error _ as error -> error
          | Ok () ->
              (try
                 let entries =
                   Sys.readdir path
                   |> Array.to_list
                   |> List.sort String.compare
                   |> List.map (fun name ->
                          let entry_path = Filename.concat path name in
                          let stats_opt =
                            try Some (Unix.lstat entry_path) with
                            | Unix.Unix_error _ -> None
                          in
                          let kind, size_bytes =
                            match stats_opt with
                            | Some stats ->
                                dir_entry_kind_of_stats stats, Some stats.Unix.st_size
                            | None -> Other, None
                          in
                          { name; kind; size_bytes })
                 in
                 Ok { path; entries }
               with
               | Sys_error message ->
                   Error (Fmt.str "Unable to list directory %s: %s" path message))))

let truncate_text ~max_bytes text =
  if String.length text <= max_bytes then text, false
  else String.sub text 0 max_bytes, true

let read_file ~workspace_root ~max_bytes raw_path =
  match resolve_workspace_root workspace_root with
  | Error _ as error -> error
  | Ok workspace_root -> (
      match resolve_path ~workspace_root raw_path with
      | Error _ as error -> error
      | Ok path -> (
          match ensure_regular_file path with
          | Error _ as error -> error
          | Ok stats ->
              let channel = open_in_bin path in
              Fun.protect
                ~finally:(fun () -> close_in_noerr channel)
                (fun () ->
                   let bytes_read = stats.Unix.st_size in
                   let content = really_input_string channel bytes_read in
                   let shown, truncated = truncate_text ~max_bytes content in
                   Ok { path; content = shown; bytes_read; truncated })))

let flush_token buffer tokens =
  if Buffer.length buffer = 0 then tokens
  else
    let token = Buffer.contents buffer in
    Buffer.clear buffer;
    token :: tokens

let parse_exec_words input =
  let buffer = Buffer.create (String.length input) in
  let rec loop index quote escaped tokens =
    if index >= String.length input then
      if escaped then Error "Trailing backslash in command."
      else
        let tokens = flush_token buffer tokens |> List.rev in
        match tokens with
        | [] -> Error "A command is required."
        | command :: args -> Ok { command; args; cwd = None }
    else
      let ch = input.[index] in
      if escaped then (
        Buffer.add_char buffer ch;
        loop (index + 1) quote false tokens)
      else
        match quote, ch with
        | _, '\\' -> loop (index + 1) quote true tokens
        | None, ('"' | '\'') -> loop (index + 1) (Some ch) false tokens
        | Some active, ch when ch = active -> loop (index + 1) None false tokens
        | None, (' ' | '\t') ->
            let tokens = flush_token buffer tokens in
            loop (index + 1) None false tokens
        | _ ->
            Buffer.add_char buffer ch;
            loop (index + 1) quote false tokens
  in
  loop 0 None false []

let exit_code_of_status = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED signal -> 128 + signal
  | Unix.WSTOPPED signal -> 128 + signal

let capture_chunk ~remaining ~truncated chunk =
  if chunk = "" then ""
  else if !remaining <= 0 then (
    truncated := true;
    "")
  else
    let keep = min (String.length chunk) !remaining in
    remaining := !remaining - keep;
    if keep < String.length chunk then truncated := true;
    if keep <= 0 then "" else String.sub chunk 0 keep

let drain_channel channel ~remaining ~truncated =
  let buffer = Buffer.create 256 in
  let rec loop () =
    Lwt_io.read ~count:4096 channel
    >>= fun chunk ->
    if chunk = "" then Lwt.return (Buffer.contents buffer)
    else (
      let kept = capture_chunk ~remaining ~truncated chunk in
      if kept <> "" then Buffer.add_string buffer kept;
      loop ())
  in
  loop ()

let with_timeout timeout_ms promise =
  Lwt.pick
    [
      promise;
      (Lwt_unix.sleep (float_of_int timeout_ms /. 1000.0) >>= fun () ->
       Lwt.fail_with "command timeout");
    ]

let exec ~workspace_root ~timeout_ms ~max_output_bytes (plan : exec_plan) =
  match resolve_workspace_root workspace_root with
  | Error _ as error -> Lwt.return error
  | Ok workspace_root -> (
      let cwd_result =
        match plan.cwd with
        | Some raw_cwd -> resolve_path ~workspace_root raw_cwd
        | None -> Ok workspace_root
      in
      match cwd_result with
      | Error _ as error -> Lwt.return error
      | Ok cwd -> (
          match ensure_directory cwd with
          | Error _ as error -> Lwt.return error
          | Ok () ->
              try
                let argv = Array.of_list (plan.command :: plan.args) in
                let process =
                  Lwt_process.open_process_full ~cwd (plan.command, argv)
                in
                let remaining = ref (max 0 max_output_bytes) in
                let truncated = ref false in
                let run =
                  Lwt.both
                    (drain_channel process#stdout ~remaining ~truncated)
                    (drain_channel process#stderr ~remaining ~truncated)
                  >>= fun (stdout, stderr) ->
                  process#status
                  >|= fun status ->
                  Ok
                    {
                      command = plan.command;
                      args = plan.args;
                      cwd;
                      exit_code = exit_code_of_status status;
                      stdout;
                      stderr;
                      truncated = !truncated;
                    }
                in
                Lwt.finalize
                  (fun () ->
                     Lwt.catch
                       (fun () -> with_timeout timeout_ms run)
                       (fun exn ->
                         process#terminate;
                         Lwt.return
                           (Error
                              (Fmt.str
                                 "Unable to run command %s: %s"
                                 plan.command
                                 (Printexc.to_string exn)))))
                  (fun () -> process#close >|= fun _ -> ())
              with
              | Unix.Unix_error (err, _, _) ->
                  Lwt.return
                    (Error
                       (Fmt.str
                          "Unable to start command %s: %s"
                          plan.command
                          (Unix.error_message err)))
              | Failure message ->
                  Lwt.return
                    (Error
                       (Fmt.str
                          "Unable to start command %s: %s"
                          plan.command
                          message))))

let dir_entry_kind_label = function
  | File -> "file"
  | Directory -> "dir"
  | Symlink -> "symlink"
  | Other -> "other"

let render_list_dir (result : list_dir_result) =
  let header =
    Fmt.str "Directory: %s (%d entries)" result.path (List.length result.entries)
  in
  header
  :: List.map
       (fun entry ->
         match entry.size_bytes with
         | Some size ->
             Fmt.str
               "  [%s] %s (%d bytes)"
               (dir_entry_kind_label entry.kind)
               entry.name
               size
         | None ->
             Fmt.str
               "  [%s] %s"
               (dir_entry_kind_label entry.kind)
               entry.name)
       result.entries

let split_lines text =
  text
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")

let render_read_file (result : read_file_result) =
  let header = Fmt.str "File: %s (%d bytes)" result.path result.bytes_read in
  let body = split_lines result.content in
  if result.truncated then header :: body @ [ "File preview truncated." ]
  else header :: body

let render_exec_result (result : exec_result) =
  let command_line =
    match result.args with
    | [] -> result.command
    | args -> String.concat " " (result.command :: args)
  in
  let base =
    [
      Fmt.str "Command: %s" command_line;
      Fmt.str "Working directory: %s" result.cwd;
      Fmt.str "Exit code: %d" result.exit_code;
    ]
  in
  let stdout_lines =
    match String.trim result.stdout with
    | "" -> []
    | value -> "stdout:" :: split_lines value
  in
  let stderr_lines =
    match String.trim result.stderr with
    | "" -> []
    | value -> "stderr:" :: split_lines value
  in
  let truncated =
    if result.truncated then [ "Command output truncated." ] else []
  in
  base @ stdout_lines @ stderr_lines @ truncated
