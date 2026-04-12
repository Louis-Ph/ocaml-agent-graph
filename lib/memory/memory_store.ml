type role =
  | User
  | Assistant

type turn = {
  turn_index : int;
  role : role;
  content : string;
}

type session = {
  summary : string option;
  reply_count : int;
  compression_count : int;
  summarized_turn_count : int;
  turn_count : int;
  recent_turns : turn list;
}

type session_ref = {
  namespace : string;
  session_key : string;
}

type t = {
  db : Sqlite3.db;
  lock : Mutex.t;
  path : string;
}

let empty_session =
  {
    summary = None;
    reply_count = 0;
    compression_count = 0;
    summarized_turn_count = 0;
    turn_count = 0;
    recent_turns = [];
  }

let timestamp_now () =
  let tm = Unix.gmtime (Unix.time ()) in
  Fmt.str
    "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900)
    (tm.tm_mon + 1)
    tm.tm_mday
    tm.tm_hour
    tm.tm_min
    tm.tm_sec

let rec ensure_dir path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o755)

let ensure_parent_dir path = ensure_dir (Filename.dirname path)

let rc_ok rc =
  rc = Sqlite3.Rc.OK || rc = Sqlite3.Rc.DONE || rc = Sqlite3.Rc.ROW

let expect_rc db context rc =
  if rc_ok rc
  then ()
  else
    failwith
      (Fmt.str
         "SQLite error during %s: %s (%s)"
         context
         (Sqlite3.Rc.to_string rc)
         (Sqlite3.errmsg db))

let exec db context sql = expect_rc db context (Sqlite3.exec db sql)

let with_stmt db sql f =
  let stmt = Sqlite3.prepare db sql in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.finalize stmt)) (fun () ->
      f stmt)

let with_lock store f =
  Mutex.lock store.lock;
  match f () with
  | result ->
      Mutex.unlock store.lock;
      result
  | exception exn ->
      Mutex.unlock store.lock;
      raise exn

let setup_schema db =
  exec db "pragma journal_mode" "PRAGMA journal_mode=WAL";
  exec db "pragma synchronous" "PRAGMA synchronous=NORMAL";
  exec db "pragma foreign_keys" "PRAGMA foreign_keys=ON";
  exec
    db
    "swarm_memory_sessions schema"
    {|CREATE TABLE IF NOT EXISTS swarm_memory_sessions (
         namespace TEXT NOT NULL,
         session_key TEXT NOT NULL,
         summary TEXT,
         reply_count INTEGER NOT NULL,
         compression_count INTEGER NOT NULL,
         summarized_turn_count INTEGER NOT NULL,
         turn_count INTEGER NOT NULL,
         updated_at TEXT NOT NULL,
         PRIMARY KEY (namespace, session_key)
       )|};
  exec
    db
    "swarm_memory_timeline schema"
    {|CREATE TABLE IF NOT EXISTS swarm_memory_timeline (
         namespace TEXT NOT NULL,
         session_key TEXT NOT NULL,
         turn_index INTEGER NOT NULL,
         role TEXT NOT NULL,
         content TEXT NOT NULL,
         created_at TEXT NOT NULL,
         PRIMARY KEY (namespace, session_key, turn_index)
       )|}

let role_to_string = function
  | User -> "user"
  | Assistant -> "assistant"

let role_of_string = function
  | "user" -> Some User
  | "assistant" -> Some Assistant
  | _ -> None

let open_store path =
  try
    ensure_parent_dir path;
    let db = Sqlite3.db_open ~mutex:`FULL path in
    exec db "busy_timeout" "PRAGMA busy_timeout=5000";
    setup_schema db;
    Ok { db; lock = Mutex.create (); path }
  with exn ->
    Error
      (Fmt.str
         "Unable to open memory store %s: %s"
         path
         (Printexc.to_string exn))

let load_session_meta_locked store (session_ref : session_ref) =
  with_stmt
    store.db
    {|SELECT summary, reply_count, compression_count, summarized_turn_count, turn_count
      FROM swarm_memory_sessions
      WHERE namespace = ? AND session_key = ?|}
    (fun stmt ->
      expect_rc
        store.db
        "bind memory namespace"
        (Sqlite3.bind_text stmt 1 session_ref.namespace);
      expect_rc
        store.db
        "bind memory session key"
        (Sqlite3.bind_text stmt 2 session_ref.session_key);
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
          {
            summary =
              (match Sqlite3.column stmt 0 with
              | Sqlite3.Data.TEXT value -> Some value
              | _ -> None);
            reply_count = Sqlite3.column_int stmt 1;
            compression_count = Sqlite3.column_int stmt 2;
            summarized_turn_count = Sqlite3.column_int stmt 3;
            turn_count = Sqlite3.column_int stmt 4;
            recent_turns = [];
          }
      | Sqlite3.Rc.DONE -> empty_session
      | rc ->
          failwith
            (Fmt.str
               "SQLite error during load_session_meta_locked: %s"
               (Sqlite3.Rc.to_string rc)))

let load_recent_turns_locked store (session_ref : session_ref) ~recent_turn_buffer =
  if recent_turn_buffer <= 0
  then []
  else
    with_stmt
      store.db
      {|SELECT turn_index, role, content
        FROM swarm_memory_timeline
        WHERE namespace = ? AND session_key = ?
        ORDER BY turn_index DESC
        LIMIT ?|}
      (fun stmt ->
        expect_rc
          store.db
          "bind recent turns namespace"
          (Sqlite3.bind_text stmt 1 session_ref.namespace);
        expect_rc
          store.db
          "bind recent turns session key"
          (Sqlite3.bind_text stmt 2 session_ref.session_key);
        expect_rc
          store.db
          "bind recent turns limit"
          (Sqlite3.bind_int stmt 3 recent_turn_buffer);
        let rec loop acc =
          match Sqlite3.step stmt with
          | Sqlite3.Rc.ROW ->
              let role =
                Sqlite3.column_text stmt 1
                |> role_of_string
                |> Option.value ~default:Assistant
              in
              loop
                ({
                   turn_index = Sqlite3.column_int stmt 0;
                   role;
                   content = Sqlite3.column_text stmt 2;
                 }
                 :: acc)
          | Sqlite3.Rc.DONE -> acc
          | rc ->
              failwith
                (Fmt.str
                   "SQLite error during load_recent_turns_locked: %s"
                   (Sqlite3.Rc.to_string rc))
        in
        loop [])

let upsert_session_meta_locked store (session_ref : session_ref) (session : session) =
  with_stmt
    store.db
    {|INSERT INTO swarm_memory_sessions (
         namespace,
         session_key,
         summary,
         reply_count,
         compression_count,
         summarized_turn_count,
         turn_count,
         updated_at
       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(namespace, session_key) DO UPDATE SET
         summary = excluded.summary,
         reply_count = excluded.reply_count,
         compression_count = excluded.compression_count,
         summarized_turn_count = excluded.summarized_turn_count,
         turn_count = excluded.turn_count,
         updated_at = excluded.updated_at|}
    (fun stmt ->
      expect_rc
        store.db
        "bind session meta namespace"
        (Sqlite3.bind_text stmt 1 session_ref.namespace);
      expect_rc
        store.db
        "bind session meta key"
        (Sqlite3.bind_text stmt 2 session_ref.session_key);
      (match session.summary with
      | Some summary ->
          expect_rc
            store.db
            "bind session meta summary"
            (Sqlite3.bind_text stmt 3 summary)
      | None ->
          expect_rc
            store.db
            "bind session meta summary null"
            (Sqlite3.bind stmt 3 Sqlite3.Data.NULL));
      expect_rc
        store.db
        "bind session meta reply_count"
        (Sqlite3.bind_int stmt 4 session.reply_count);
      expect_rc
        store.db
        "bind session meta compression_count"
        (Sqlite3.bind_int stmt 5 session.compression_count);
      expect_rc
        store.db
        "bind session meta summarized_turn_count"
        (Sqlite3.bind_int stmt 6 session.summarized_turn_count);
      expect_rc
        store.db
        "bind session meta turn_count"
        (Sqlite3.bind_int stmt 7 session.turn_count);
      expect_rc
        store.db
        "bind session meta updated_at"
        (Sqlite3.bind_text stmt 8 (timestamp_now ()));
      expect_rc store.db "upsert session meta" (Sqlite3.step stmt))

let load_session store session_ref ~recent_turn_buffer =
  with_lock store (fun () ->
      let session = load_session_meta_locked store session_ref in
      {
        session with
        recent_turns =
          load_recent_turns_locked store session_ref ~recent_turn_buffer;
      })

let append_exchange
    store
    session_ref
    ~recent_turn_buffer
    ~user_content
    ~assistant_content
  =
  with_lock store (fun () ->
      let turns_to_append =
        [
          User, String.trim user_content;
          Assistant, String.trim assistant_content;
        ]
        |> List.filter (fun (_, content) -> content <> "")
      in
      let session = load_session_meta_locked store session_ref in
      if turns_to_append = []
      then
        {
          session with
          recent_turns =
            load_recent_turns_locked store session_ref ~recent_turn_buffer;
        }
      else (
        exec store.db "begin append exchange" "BEGIN IMMEDIATE";
        try
          turns_to_append
          |> List.iteri (fun offset (role, content) ->
                 with_stmt
                   store.db
                   {|INSERT INTO swarm_memory_timeline (
                        namespace,
                        session_key,
                        turn_index,
                        role,
                        content,
                        created_at
                      ) VALUES (?, ?, ?, ?, ?, ?)|}
                   (fun stmt ->
                     expect_rc
                       store.db
                       "bind append turn namespace"
                       (Sqlite3.bind_text stmt 1 session_ref.namespace);
                     expect_rc
                       store.db
                       "bind append turn session key"
                       (Sqlite3.bind_text stmt 2 session_ref.session_key);
                     expect_rc
                       store.db
                       "bind append turn index"
                       (Sqlite3.bind_int stmt 3 (session.turn_count + offset));
                     expect_rc
                       store.db
                       "bind append turn role"
                       (Sqlite3.bind_text stmt 4 (role_to_string role));
                     expect_rc
                       store.db
                       "bind append turn content"
                       (Sqlite3.bind_text stmt 5 content);
                     expect_rc
                       store.db
                       "bind append turn created_at"
                       (Sqlite3.bind_text stmt 6 (timestamp_now ()));
                     expect_rc store.db "insert append turn" (Sqlite3.step stmt)));
          let updated =
            {
              session with
              reply_count = session.reply_count + 1;
              turn_count = session.turn_count + List.length turns_to_append;
            }
          in
          upsert_session_meta_locked store session_ref updated;
          exec store.db "commit append exchange" "COMMIT";
          {
            updated with
            recent_turns =
              load_recent_turns_locked store session_ref ~recent_turn_buffer;
          }
        with exn ->
          ignore (Sqlite3.exec store.db "ROLLBACK");
          raise exn))

let load_turns_range
    store
    (session_ref : session_ref)
    ~first_turn_index
    ~past_last_turn_index
  =
  if past_last_turn_index <= first_turn_index
  then []
  else
    with_lock store (fun () ->
        with_stmt
          store.db
          {|SELECT turn_index, role, content
            FROM swarm_memory_timeline
            WHERE namespace = ?
              AND session_key = ?
              AND turn_index >= ?
              AND turn_index < ?
            ORDER BY turn_index ASC|}
          (fun stmt ->
            expect_rc
              store.db
              "bind range namespace"
              (Sqlite3.bind_text stmt 1 session_ref.namespace);
            expect_rc
              store.db
              "bind range session key"
              (Sqlite3.bind_text stmt 2 session_ref.session_key);
            expect_rc
              store.db
              "bind range first index"
              (Sqlite3.bind_int stmt 3 first_turn_index);
            expect_rc
              store.db
              "bind range past last index"
              (Sqlite3.bind_int stmt 4 past_last_turn_index);
            let rec loop acc =
              match Sqlite3.step stmt with
              | Sqlite3.Rc.ROW ->
                  let role =
                    Sqlite3.column_text stmt 1
                    |> role_of_string
                    |> Option.value ~default:Assistant
                  in
                  loop
                    ({
                       turn_index = Sqlite3.column_int stmt 0;
                       role;
                       content = Sqlite3.column_text stmt 2;
                     }
                     :: acc)
              | Sqlite3.Rc.DONE -> List.rev acc
              | rc ->
                  failwith
                    (Fmt.str
                       "SQLite error during load_turns_range: %s"
                       (Sqlite3.Rc.to_string rc))
            in
            loop []))

let update_summary
    store
    session_ref
    ~recent_turn_buffer
    ~summary
    ~compression_count
    ~summarized_turn_count
  =
  with_lock store (fun () ->
      let session = load_session_meta_locked store session_ref in
      let updated =
        {
          session with
          summary;
          compression_count;
          summarized_turn_count;
        }
      in
      upsert_session_meta_locked store session_ref updated;
      {
        updated with
        recent_turns =
          load_recent_turns_locked store session_ref ~recent_turn_buffer;
      })

let clear_session store (session_ref : session_ref) =
  with_lock store (fun () ->
      exec store.db "begin clear memory session" "BEGIN IMMEDIATE";
      try
        with_stmt
          store.db
          "DELETE FROM swarm_memory_timeline WHERE namespace = ? AND session_key = ?"
          (fun stmt ->
            expect_rc
              store.db
              "bind clear timeline namespace"
              (Sqlite3.bind_text stmt 1 session_ref.namespace);
            expect_rc
              store.db
              "bind clear timeline session key"
              (Sqlite3.bind_text stmt 2 session_ref.session_key);
            expect_rc store.db "delete memory timeline" (Sqlite3.step stmt));
        with_stmt
          store.db
          "DELETE FROM swarm_memory_sessions WHERE namespace = ? AND session_key = ?"
          (fun stmt ->
            expect_rc
              store.db
              "bind clear session namespace"
              (Sqlite3.bind_text stmt 1 session_ref.namespace);
            expect_rc
              store.db
              "bind clear session key"
              (Sqlite3.bind_text stmt 2 session_ref.session_key);
            expect_rc store.db "delete memory session" (Sqlite3.step stmt));
        exec store.db "commit clear memory session" "COMMIT"
      with exn ->
        ignore (Sqlite3.exec store.db "ROLLBACK");
        raise exn)
