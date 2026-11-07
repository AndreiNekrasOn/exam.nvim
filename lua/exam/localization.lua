-- Default UI and export strings.
-- Override globally via setup({ texts = { ... } }) or per exam via options.texts.
-- Only the plugin interface is localized; warnings and notifications are not.
local M = {}

M.TEXTS = {
  -- buttons / strips
  start = "START",
  pause = "PAUSE",
  commit = "COMMIT",
  uncommit = "UNCOMMIT",
  skip = "SKIP",
  unskip = "UNSKIP",
  time = "Time",
  before_start = "Exam not started",
  paused = "Paused",

  -- export
  export_before = "BEFORE TIME UP",
  export_after = "AFTER TIME UP",
  export_exam = "Exam",
  export_date = "Date",
  export_limit = "Time limit",
  export_total = "Total",
  export_overdraft = "Overdraft",
  export_skipped = "\u{2014}",
  minutes = "min",
  minutes_short = "m",
}

return M
