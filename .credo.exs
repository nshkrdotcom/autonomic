%{
  configs: [
    %{
      name: "default",
      files: %{included: ["apps/", "config/"]},
      strict: true,
      checks: %{
        disabled: [
          {Credo.Check.Readability.ModuleDoc, false},
          {Credo.Check.Design.AliasUsage, false}
        ]
      }
    }
  ]
}
