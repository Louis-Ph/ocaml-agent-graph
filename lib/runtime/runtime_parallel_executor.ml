let run_all ~services ~config ~registry agents context payload =
  Lwt_list.map_p
    (fun agent ->
      Runtime_engine.run_agent ~services ~config ~registry agent context payload)
    agents
