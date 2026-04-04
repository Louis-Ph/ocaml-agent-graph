open Agent_graph
open Yojson.Safe.Util

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when String.trim root <> "" -> root
  | _ -> Sys.getcwd ()

let repo_path relative = Filename.concat (source_root ()) relative

let load_json relative = Yojson.Safe.from_file (repo_path relative)

let existing_directory path =
  try (Unix.stat path).Unix.st_kind = Unix.S_DIR with
  | Unix.Unix_error _ -> false

let existing_file path =
  try (Unix.stat path).Unix.st_kind = Unix.S_REG with
  | Unix.Unix_error _ -> false

let string_member_opt name json =
  match json |> member name with
  | `String value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let bool_member_opt name json =
  match json |> member name with
  | `Bool value -> Some value
  | _ -> None

let scenario_bool name json =
  match name with
  | "requires_real_llm" ->
      (match bool_member_opt name json with
       | Some value -> Some value
       | None -> bool_member_opt name (json |> member "runtime_mode"))
  | "uses_multiple_llms" ->
      (match bool_member_opt name json with
       | Some value -> Some value
       | None -> bool_member_opt name (json |> member "runtime_mode"))
  | "requires_web_crawler" ->
      (match bool_member_opt "requires_web_crawler" json with
       | Some value -> Some value
       | None ->
           (match bool_member_opt "requires_real_web_crawler" json with
            | Some value -> Some value
            | None ->
                bool_member_opt "requires_real_web_crawler" (json |> member "runtime_mode")))
  | _ -> None

let sorted = List.sort String.compare

let test_catalog_covers_procurement_demo_packs () =
  let catalog = load_json "demos/catalog.json" in
  Alcotest.(check int) "catalog version" 1 (catalog |> member "version" |> to_int);
  Alcotest.(check string)
    "catalog domain"
    "procurement"
    (catalog |> member "domain" |> to_string);
  let scenarios = catalog |> member "scenarios" |> to_list in
  let catalog_ids =
    scenarios |> List.map (fun json -> json |> member "id" |> to_string)
  in
  let demo_directories =
    Sys.readdir (repo_path "demos")
    |> Array.to_list
    |> List.filter (fun name ->
           let path = repo_path (Filename.concat "demos" name) in
           existing_directory path && name <> "adaptive_webcrawler")
  in
  Alcotest.(check (list string))
    "catalog matches procurement folders"
    (sorted demo_directories)
    (sorted catalog_ids)

let test_catalog_entries_match_demo_contracts () =
  let catalog = load_json "demos/catalog.json" in
  let scenarios = catalog |> member "scenarios" |> to_list in
  List.iter
    (fun entry ->
      let scenario_id = entry |> member "id" |> to_string in
      let title = entry |> member "title" |> to_string in
      let scenario_dir = repo_path (Filename.concat "demos" scenario_id) in
      let readme_path = Filename.concat scenario_dir "README.md" in
      let scenario_path = Filename.concat scenario_dir "scenario.json" in
      Alcotest.(check bool)
        (Fmt.str "%s README exists" scenario_id)
        true
        (existing_file readme_path);
      Alcotest.(check bool)
        (Fmt.str "%s scenario exists" scenario_id)
        true
        (existing_file scenario_path);
      let scenario = Yojson.Safe.from_file scenario_path in
      let scenario_title =
        match string_member_opt "title" scenario with
        | Some value -> value
        | None -> Alcotest.fail (Fmt.str "%s is missing title" scenario_id)
      in
      Alcotest.(check string)
        (Fmt.str "%s title matches catalog" scenario_id)
        title
        scenario_title;
      let effective_id =
        match string_member_opt "scenario_id" scenario with
        | Some value -> value
        | None ->
            (match string_member_opt "scenario_name" scenario with
             | Some value -> value
             | None -> Alcotest.fail (Fmt.str "%s is missing scenario id" scenario_id))
      in
      Alcotest.(check string)
        (Fmt.str "%s id matches folder" scenario_id)
        scenario_id
        effective_id;
      List.iter
        (fun (catalog_name, expected) ->
          match scenario_bool catalog_name scenario with
          | Some actual ->
              Alcotest.(check bool)
                (Fmt.str "%s %s matches" scenario_id catalog_name)
                expected
                actual
          | None ->
              Alcotest.fail
                (Fmt.str "%s is missing boolean %s" scenario_id catalog_name))
        [
          "requires_real_llm", entry |> member "requires_real_llm" |> to_bool;
          "uses_multiple_llms", entry |> member "uses_multiple_llms" |> to_bool;
          "requires_web_crawler", entry |> member "requires_web_crawler" |> to_bool;
        ])
    scenarios

let test_runtime_demo_config_loads () =
  match Config.Runtime.load (repo_path "config/runtime.json") with
  | Error message -> Alcotest.fail message
  | Ok config ->
      Alcotest.(check string)
        "runtime demo task id"
        "demo-task-001"
        config.demo.task_id;
      Alcotest.(check bool)
        "runtime gateway config exists"
        true
        (existing_file config.llm.gateway_config_path)

let test_adaptive_webcrawler_demo_pack_loads () =
  match Web_crawler.Config.load (repo_path "demos/adaptive_webcrawler/scenario.json") with
  | Error message -> Alcotest.fail message
  | Ok config ->
      Alcotest.(check string)
        "scenario name"
        "adaptive-webcrawler"
        config.scenario_name;
      Alcotest.(check string)
        "task id"
        "adaptive-crawl-demo"
        config.task_id;
      Alcotest.(check bool)
        "objective non-empty"
        true
        (String.trim config.objective <> "");
      Alcotest.(check bool)
        "seed queries exist"
        true
        (List.length config.seed_queries >= 1);
      Alcotest.(check bool)
        "gateway config exists"
        true
        (existing_file config.llm.gateway_config_path);
      Alcotest.(check bool)
        "reflector prompt loaded"
        true
        (String.trim config.llm.reflector.prompt <> "");
      Alcotest.(check bool)
        "reporter prompt loaded"
        true
        (String.trim config.llm.reporter.prompt <> "");
      Alcotest.(check bool)
        "output template loaded"
        true
        (match config.output_template with
         | Some text -> String.trim text <> ""
         | None -> false)

let () =
  Alcotest.run
    "agent-graph-demos"
    [
      ( "catalog",
        [
          Alcotest.test_case
            "covers procurement demo packs"
            `Quick
            test_catalog_covers_procurement_demo_packs;
          Alcotest.test_case
            "entries match demo contracts"
            `Quick
            test_catalog_entries_match_demo_contracts;
        ] );
      ( "configs",
        [
          Alcotest.test_case
            "runtime demo config loads"
            `Quick
            test_runtime_demo_config_loads;
          Alcotest.test_case
            "adaptive webcrawler demo pack loads"
            `Quick
            test_adaptive_webcrawler_demo_pack_loads;
        ] );
    ]
