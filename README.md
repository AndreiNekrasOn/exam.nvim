# exam.nvim

Neovim plugin for taking written exams: exam timer, per-question timing, question statuses, answer drafts, and result export. Requires Neovim 0.10+.

## LLM Usage Notice

Fully vibecoded, I haven't looked at the code at all. I just needed this tool for myself. Use at your own risk.

## Commands

| Action | UI | Command | Function |
| --- | --- | --- | --- |
| Start or resume an exam | — | `:ExamRun <name> [path]` | — |
| Start / resume the timers | `[ START ]` / `[ PAUSE ]` | `:ExamStart` / `:ExamPause` | `exam.start` / `exam.pause` |
| Open a specific question | click it in the sidebar or questions list | `:ExamQuestion <name>` | `exam.open_question` |
| Next / previous question | — | `:ExamQuestionNext` / `:ExamQuestionPrev` | `exam.focus_next` / `exam.focus_prev` |
| Commit / uncommit the current question | `[ COMMIT ]` / `[ UNCOMMIT ]` | `:ExamQuestionCommit` / `:ExamQuestionUncommit` | `exam.commit` / `exam.uncommit` |
| Skip / unskip the current question | `[ SKIP ]` / `[ UNSKIP ]` | `:ExamQuestionSkip` / `:ExamQuestionUnskip` | `exam.skip` / `exam.unskip` |
| Open the questions list | — | `:ExamQuestions` | `exam.open_questions` |
| Toggle the UI | — | `:ExamToggleUI` | `exam.toggle_ui` |
| Export the result | — | `:ExamExport <file>` / `:ExamExportAndPause <file>` | `exam.export` / `exam.export_and_pause` |

All buttons are clickable with the mouse. The questions list also offers navigation helpers you can bind:

```lua
local q = require("exam").questions
vim.keymap.set("n", "]q", q.find_next, { buffer = true }) -- next question from cursor
vim.keymap.set("n", "]b", q.next_button, { buffer = true }) -- next button
```

## Statuses

| Status | Style |
| --- | --- |
| `not_started` | grey |
| `started` | normal |
| `current` | bold |
| `committed` | green |
| `skipped` | strikethrough |

A committed draft is read-only until uncommitted; a question can be skipped only while empty.

## Exam manifest

`exam.yaml`, passed to `:ExamRun`; durations are integer minutes. Question `name` is its identifier used everywhere.

```yaml
title: "Test Exam"
time_minutes: 45
sections:
  - name: Section A
    questions:
      - name: 1
        text: "Test question 1"
        recommended_minutes: 2
      - name: 2
        text: "Test question 2"
        recommended_minutes: 2
options: # all optional; override the plugin config, manifest wins
  show_recommended: true
  write_on_time_up: true
  texts:
    commit: "COMMIT"
```

`text` may span several lines. Use a YAML block scalar (`|-` keeps no trailing newline, `|` keeps one, `>` folds) or `\n` inside double quotes; plain indented lines are not valid YAML:

```yaml
- name: 1
  text: |-
    First line
    second line
```

## Plugin configuration

```lua
require("exam").setup({
  show_recommended = false, -- show recommended time
  write_on_time_up = true, -- snapshot the state when overdraft starts
  hide_list_before_start = false, -- hide the questions list before start
  hide_list_message = "",
  overdraft_thresholds = { first = 300, second = 600, fraction = 0.33 }, -- seconds/ratio
  texts = {}, -- override UI/export strings
})
```

## Export

`:ExamExport <file>` writes the result; `:ExamExportAndPause` also pauses (the session stays resumable). With overdraft, a `## AFTER TIME UP` section is appended: its table lists every question that got time after the limit (so you can see where the overdraft went), while the per-question bodies are only shown for questions whose answer text changed.

```markdown
## BEFORE TIME UP

Exam: Test Exam · Date: 2026-01-01 · Time limit: 45 min · Total: 47:10

| Name | Section | Time |
| ---- | ------- | ---- |
| 1 | Section A | 03:12 |
| 2 | Section A | 00:00 |

### Section A

#### 1. Test question 1

Answer body.

#### 2. Test question 2

—
```

## Credits

Vendored YAML parser: [`cvigilv/yaml.nvim`](https://github.com/cvigilv/yaml.nvim) (MIT), copied to `lua/exam/yaml.lua` with its license header.
