(lang dune 3.21)

(name ocaml-agent-graph)

(generate_opam_files true)

(package
 (name ocaml-agent-graph)
 (synopsis "Typed multi-agent orchestration in OCaml")
 (description
  "Modular LangGraph/CrewAI-inspired orchestration runtime in OCaml with Lwt, typed routing, retries, timeouts, and tests.")
 (depends
  (ocaml
   (>= 5.2.0))
  (dune
   (>= 3.21))
  lwt
  yojson
  fmt
  aegis_lm
  cmdliner
  (alcotest :with-test)))
