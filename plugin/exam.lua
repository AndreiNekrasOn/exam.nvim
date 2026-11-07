if vim.g.loaded_exam_nvim then
  return
end
vim.g.loaded_exam_nvim = true

local exam = require("exam")

local function map(fn)
  return function(args)
    fn(args)
  end
end

vim.api.nvim_create_user_command("ExamRun", map(function(a)
  exam.run(a.args)
end), { nargs = "*", desc = "Start or resume an exam" })

vim.api.nvim_create_user_command("ExamStart", function()
  exam.start()
end, { desc = "Start or resume the exam timers" })

vim.api.nvim_create_user_command("ExamPause", function()
  exam.pause()
end, { desc = "Pause the exam timers" })

vim.api.nvim_create_user_command("ExamQuestion", map(function(a)
  exam.open_question(a.args)
end), { nargs = 1, desc = "Open a specific question" })

vim.api.nvim_create_user_command("ExamQuestionNext", function()
  exam.focus_next()
end, { desc = "Open the next question" })

vim.api.nvim_create_user_command("ExamQuestionPrev", function()
  exam.focus_prev()
end, { desc = "Open the previous question" })

vim.api.nvim_create_user_command("ExamQuestionCommit", function()
  exam.commit()
end, { desc = "Commit the current question" })

vim.api.nvim_create_user_command("ExamQuestionUncommit", function()
  exam.uncommit()
end, { desc = "Uncommit the current question" })

vim.api.nvim_create_user_command("ExamQuestionSkip", function()
  exam.skip()
end, { desc = "Skip the current question" })

vim.api.nvim_create_user_command("ExamQuestionUnskip", function()
  exam.unskip()
end, { desc = "Unskip the current question" })

vim.api.nvim_create_user_command("ExamQuestions", function()
  exam.open_questions()
end, { desc = "Open the questions list" })

vim.api.nvim_create_user_command("ExamToggleUI", function()
  exam.toggle_ui()
end, { desc = "Toggle the exam UI" })

vim.api.nvim_create_user_command("ExamExport", map(function(a)
  exam.export(a.args)
end), { nargs = 1, complete = "file", desc = "Export the result" })

vim.api.nvim_create_user_command("ExamExportAndPause", map(function(a)
  exam.export_and_pause(a.args)
end), { nargs = 1, complete = "file", desc = "Export the result and pause" })
