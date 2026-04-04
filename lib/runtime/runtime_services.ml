type t = {
  config : Runtime_config.t;
  llm_client : Llm_aegis_client.t;
}

let create config =
  match Llm_aegis_client.create config.Runtime_config.llm with
  | Error _ as error -> error
  | Ok llm_client ->
      (match
         Llm_aegis_client.validate_agent_profiles
           llm_client
           config.Runtime_config.llm
       with
       | Error _ as error -> error
       | Ok () -> Ok { config; llm_client })

let of_llm_client ~config llm_client = { config; llm_client }
