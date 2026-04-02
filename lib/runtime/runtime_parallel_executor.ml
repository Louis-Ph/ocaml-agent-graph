let run_all ~config ~registry agents context payload =
  Lwt_list.map_p
    (fun agent -> Runtime_engine.run_agent ~config ~registry agent context payload)
    agents

