%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "src/",
          "web/",
          "apps/*/lib/",
          "apps/*/src/",
          "apps/*/web/"
        ],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: [
        {Credo.Check.Warning.UnsafeToAtom, []},
        {Credo.Check.Readability.ModuleDoc, false},
        {Credo.Check.Design.TagTODO, false},
        {Credo.Check.Design.TagFIXME, false},
        {Credo.Check.Refactor.LongQuoteBlocks, false},
        {Credo.Check.Refactor.PipeChainStart, []},
        {Credo.Check.Readability.SinglePipe, []}
      ]
    }
  ]
}
