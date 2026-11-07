-- exam.nvim: a Neovim plugin for taking written exams.
-- Main module. Thin command registration lives in plugin/exam.lua.
local yaml = require("exam.yaml")
local texts_mod = require("exam.localization")

local M = {}
M.questions = {}

--------------------------------------------------------------------------------
-- Defaults and state
--------------------------------------------------------------------------------

local defaults = {
  show_recommended = false,
  write_on_time_up = true,
  hide_list_before_start = false,
  hide_list_message = "",
  overdraft_thresholds = { first = 300, second = 600, fraction = 0.33 },
  highlights = {},
  texts = {},
}

local state = {
  active = false,
  running = false,
  exam_accum = 0,
  q_accum = {},
  statuses = {},
  bufs = {},
  actions = {},
  buttons = {},
  texts = texts_mod.TEXTS,
  ns = vim.api.nvim_create_namespace("exam.nvim"),
  -- populated at runtime
  user_config = nil,
  dir = nil,
  drafts_dir = nil,
  manifest = nil,
  config = nil,
  title = nil,
  limit_sec = nil,
  questions = {},
  order = {},
  current = nil,
  active_since = nil,
  q_since = nil,
  started_once = false,
  overdraft_started = false,
  snapshot_written = false,
  timer = nil,
  main_win = nil,
  timer_win = nil,
  sidebar_win = nil,
  strip_win = nil,
  timer_buf = nil,
  sidebar_buf = nil,
  strip_buf = nil,
  ql_buf = nil,
}

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function notify(msg, level)
  vim.notify("exam.nvim: " .. tostring(msg), level or vim.log.levels.INFO)
end

local function fmt_time(sec)
  sec = math.max(0, math.floor(sec or 0))
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60
  if h > 0 then
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%02d:%02d", m, s)
end

local function sanitize(name)
  return (tostring(name):gsub("[^%w%-_%.]", "_"))
end

local function resolved(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and type(hl) == "table" then
    return hl
  end
  return {}
end

local function with(base, extra)
  local hl = resolved(base)
  for k, v in pairs(extra or {}) do
    hl[k] = v
  end
  hl.link = nil
  return hl
end

local function set_hl(name, spec)
  pcall(vim.api.nvim_set_hl, 0, name, spec)
end

local function buf_ok(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function win_ok(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function ensure_mouse()
  if not vim.o.mouse:find("n") then
    vim.opt.mouse:append("n")
  end
end

-- Forward declaration: defined in the "Exam actions" section, needed by the UI.
local apply_status

-- Forward declarations: defined in the panel/UI section, needed by build_sidebar.
local panel_width, clip_display

local status_suffix = {
  not_started = "NotStarted",
  started = "Started",
  committed = "Committed",
  skipped = "Skipped",
}

local function apply_highlights(overrides)
  set_hl("ExamNotStarted", with("Comment"))
  set_hl("ExamStarted", {})
  set_hl("ExamCommitted", with("DiagnosticOk"))
  set_hl("ExamSkipped", with("DiagnosticError", { strikethrough = true }))
  set_hl("ExamSection", with("Title", { bold = true }))
  set_hl("ExamQuestionText", with("Comment"))
  set_hl("ExamRule", with("NonText"))
  set_hl("ExamButton", with("Function"))
  set_hl("ExamButtonDisabled", with("Comment"))
  set_hl("ExamTimerOk", with("DiagnosticInfo"))
  set_hl("ExamTimerWarn", with("DiagnosticWarn"))
  set_hl("ExamTimerOrange", { fg = "#ff8700" })
  set_hl("ExamTimerRed", with("DiagnosticError"))
  for _, suffix in pairs(status_suffix) do
    set_hl("ExamCurrent" .. suffix, with("DiagnosticInfo", { bold = true }))
  end
  -- Committed colour outranks the current (blue) colour, but current stays bold.
  set_hl("ExamCurrentCommitted", with("ExamCommitted", { bold = true }))
  for name, spec in pairs(overrides or {}) do
    set_hl(name, spec)
  end
end

--------------------------------------------------------------------------------
-- Paths and file IO
--------------------------------------------------------------------------------

local function data_root()
  return vim.fn.stdpath("data") .. "/exam.nvim"
end

local function exam_dir(name)
  return data_root() .. "/" .. sanitize(name)
end

local function draft_path(name)
  return state.drafts_dir .. "/" .. sanitize(name) .. ".md"
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local c = f:read("*a")
  f:close()
  return c
end

local function write_file(path, content)
  local f = io.open(path, "w")
  if not f then
    return false
  end
  f:write(content)
  f:close()
  return true
end

--------------------------------------------------------------------------------
-- Events, persistence and timer reconstruction
--------------------------------------------------------------------------------

local function log_event_at(dir, kind, extra)
  local ev = { t = os.time(), type = kind }
  for k, v in pairs(extra or {}) do
    ev[k] = v
  end
  local f = io.open(dir .. "/events.ndjson", "a")
  if f then
    f:write(vim.json.encode(ev) .. "\n")
    f:close()
  end
end

local function log_event(kind, extra)
  if state.dir then
    log_event_at(state.dir, kind, extra)
  end
end

local function save_state()
  if not state.dir then
    return
  end
  local s = { statuses = state.statuses, current = state.current }
  write_file(state.dir .. "/state.json", vim.json.encode(s))
end

local function load_state_json()
  state.statuses = {}
  local c = read_file(state.dir .. "/state.json")
  if not c then
    return
  end
  local ok, d = pcall(vim.json.decode, c)
  if ok and type(d) == "table" then
    state.statuses = d.statuses or {}
  end
end

local function read_events(path)
  local events = {}
  if vim.fn.filereadable(path) ~= 1 then
    return events
  end
  for line in io.lines(path) do
    local ok, ev = pcall(vim.json.decode, line)
    if ok and type(ev) == "table" and ev.t then
      events[#events + 1] = ev
    end
  end
  return events
end

-- Add the interval up to `t` into the accumulated times and advance the marks.
local function accrue(ctx, t)
  if ctx.running and ctx.active_since then
    state.exam_accum = state.exam_accum + (t - ctx.active_since)
    if ctx.current and ctx.q_since then
      state.q_accum[ctx.current] = (state.q_accum[ctx.current] or 0) + (t - ctx.q_since)
    end
    ctx.active_since = t
    if ctx.current then
      ctx.q_since = t
    end
  end
end

local function new_timer_ctx()
  return {
    running = false,
    active_since = nil,
    q_since = nil,
    current = nil,
    last_t = nil,
    started_once = false,
    overdraft_started = false,
  }
end

local function apply_event(ev, ctx)
  local t = ev.t
  if ev.type == "start" or ev.type == "resume" then
    if not ctx.running then
      ctx.running, ctx.active_since, ctx.q_since = true, t, t
    end
    ctx.started_once = true
  elseif ev.type == "pause" or ev.type == "close" then
    accrue(ctx, t)
    ctx.running, ctx.active_since, ctx.q_since = false, nil, nil
  elseif ev.type == "enter_question" then
    accrue(ctx, t)
    ctx.current = ev.name
    ctx.q_since = ctx.running and t or nil
  elseif ev.type == "overdraft_start" then
    ctx.overdraft_started = true
  end
  ctx.last_t = t
end

-- Rebuild accumulated times from the event log (wall-clock based).
local function reconstruct()
  state.exam_accum = 0
  state.q_accum = {}
  state.current = nil
  state.running = false
  state.active_since = nil
  state.q_since = nil
  local ctx = new_timer_ctx()
  for _, ev in ipairs(read_events(state.dir .. "/events.ndjson")) do
    apply_event(ev, ctx)
  end
  if ctx.running and ctx.active_since and ctx.last_t then
    accrue(ctx, ctx.last_t)
  end
  state.current = ctx.current
  state.started_once = ctx.started_once
  state.overdraft_started = ctx.overdraft_started
end

local function exam_elapsed()
  local e = state.exam_accum or 0
  if state.running and state.active_since then
    e = e + (os.time() - state.active_since)
  end
  return e
end

local function q_elapsed(name)
  local e = (state.q_accum and state.q_accum[name]) or 0
  if state.running and state.current == name and state.q_since then
    e = e + (os.time() - state.q_since)
  end
  return e
end

-- Overdraft color level: 0 none, 1 yellow, 2 orange, 3 red.
local function od_level(od, limit_sec, th)
  if od <= 0 then
    return 0
  end
  if od > th.fraction * limit_sec then
    return 3
  end
  if od > th.second then
    return 2
  end
  if od > th.first then
    return 1
  end
  return 0
end

--------------------------------------------------------------------------------
-- Drafts and statuses
--------------------------------------------------------------------------------

local function write_buf(buf)
  if not buf_ok(buf) or not vim.bo[buf].modified then
    return
  end
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent! write")
  end)
end

local function buffer_for(name)
  return buf_ok(state.bufs[name]) and state.bufs[name] or nil
end

local function has_text(name)
  local buf = buffer_for(name)
  if buf then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    return table.concat(lines, "\n"):match("%S") ~= nil
  end
  local c = read_file(draft_path(name))
  return c ~= nil and c:match("%S") ~= nil
end

local function body_of(name)
  local buf = buffer_for(name)
  if buf then
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end
  return read_file(draft_path(name)) or ""
end

local function rows_from(questions)
  local rows = {}
  for _, q in ipairs(questions) do
    rows[#rows + 1] = {
      name = q.name,
      section = q.section,
      text = q.text,
      time = q_elapsed(q.name),
      body = body_of(q.name),
    }
  end
  return rows
end

local function status_of(name)
  local stored = state.statuses[name]
  if stored == "skipped" and has_text(name) then
    return "started"
  end
  if stored then
    return stored
  end
  return has_text(name) and "started" or "not_started"
end

-- Highlight group for a question line. The status colour wins over the current
-- colour (a committed question stays green), while the current one is always bold.
local function question_hl(name)
  local st = status_of(name)
  if state.current == name then
    return st == "committed" and "ExamCurrentCommitted" or ("ExamCurrent" .. status_suffix[st])
  end
  return "Exam" .. status_suffix[st]
end

-- Switch the "current" question (timer follows it). Shared by open_question and BufEnter.
local function enter_question(name)
  local now = os.time()
  accrue(state, now) -- flush the current interval
  state.current = name
  state.q_since = state.running and now or nil
  log_event("enter_question", { name = name })
  save_state()
end

local function write_snapshot()
  local snap = {
    title = state.title,
    date = os.date("%Y-%m-%d"),
    time_minutes = state.manifest.time_minutes,
    elapsed = exam_elapsed(),
    questions = rows_from(state.questions),
  }
  write_file(state.dir .. "/on-time-up.json", vim.json.encode(snap))
  state.snapshot_written = true
end

local function read_snapshot()
  local c = read_file(state.dir .. "/on-time-up.json")
  if not c then
    return nil
  end
  local ok, d = pcall(vim.json.decode, c)
  if ok then
    return d
  end
  return nil
end

local function check_overdraft()
  local od = exam_elapsed() - state.limit_sec
  if od <= 0 then
    return
  end
  if not state.overdraft_started then
    state.overdraft_started = true
    log_event("overdraft_start")
  end
  if state.config.write_on_time_up and not state.snapshot_written then
    write_snapshot()
  end
end

--------------------------------------------------------------------------------
-- Manifest loading
--------------------------------------------------------------------------------

-- Parse and validate the manifest. Configuration errors fail loudly.
local function validate_question(q, seen)
  if type(q) ~= "table" or (type(q.name) ~= "string" and type(q.name) ~= "number") or tostring(q.name) == "" then
    error("exam.yaml: each question needs a non-empty 'name'", 0)
  end
  q.name = tostring(q.name)
  if seen[q.name] then
    error("exam.yaml: duplicate question name '" .. q.name .. "'", 0)
  end
  seen[q.name] = true
  local san = sanitize(q.name)
  if seen["\0" .. san] then
    error("exam.yaml: question name '" .. q.name .. "' collides with another after sanitization", 0)
  end
  seen["\0" .. san] = true
  if type(q.text) == "number" then
    q.text = tostring(q.text)
  end
  if q.text ~= nil and type(q.text) ~= "string" then
    error("exam.yaml: question '" .. q.name .. "': 'text' must be a string", 0)
  end
  local r = q.recommended_minutes
  if r ~= nil and (type(r) ~= "number" or r < 0 or r % 1 ~= 0) then
    error("exam.yaml: question '" .. q.name .. "': 'recommended_minutes' must be a non-negative integer", 0)
  end
end

local function validate_section(sec, seen)
  if type(sec) ~= "table" or (type(sec.name) ~= "string" and type(sec.name) ~= "number") then
    error("exam.yaml: each section needs a 'name'", 0)
  end
  sec.name = tostring(sec.name)
  if type(sec.questions) ~= "table" or #sec.questions == 0 then
    error("exam.yaml: section '" .. sec.name .. "' has no questions", 0)
  end
  for _, q in ipairs(sec.questions) do
    validate_question(q, seen)
  end
end

local function load_manifest(content)
  local data, err = yaml.parse(content)
  if not data then
    error("exam.yaml: " .. tostring(err), 0)
  end
  if type(data) ~= "table" then
    error("exam.yaml: invalid document", 0)
  end
  if type(data.title) == "number" then
    data.title = tostring(data.title)
  end
  if type(data.title) ~= "string" then
    error("exam.yaml: 'title' is required", 0)
  end
  local t = data.time_minutes
  if type(t) ~= "number" or t <= 0 or t % 1 ~= 0 then
    error("exam.yaml: 'time_minutes' must be a positive integer", 0)
  end
  if type(data.sections) ~= "table" or #data.sections == 0 then
    error("exam.yaml: 'sections' is required", 0)
  end
  local seen = {}
  for _, sec in ipairs(data.sections) do
    validate_section(sec, seen)
  end
  return data
end

local function flatten_questions(manifest)
  local list = {}
  for _, sec in ipairs(manifest.sections) do
    for i, q in ipairs(sec.questions) do
      list[#list + 1] = {
        name = q.name,
        text = q.text or "",
        section = sec.name,
        recommended = q.recommended_minutes or 0,
        new_section = (i == 1),
      }
    end
  end
  state.questions = list
  state.order = {}
  for i, q in ipairs(list) do
    state.order[q.name] = i
  end
end

--------------------------------------------------------------------------------
-- Question buffers
--------------------------------------------------------------------------------

local function setup_question_autocmds(name, buf)
  local grp = vim.api.nvim_create_augroup("ExamQ_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = grp,
    buffer = buf,
    callback = function()
      if state.statuses[name] == "skipped" and has_text(name) then
        state.statuses[name] = nil
      end
      M.render()
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = grp,
    buffer = buf,
    callback = function()
      if state.active and state.current ~= name then
        enter_question(name)
        M.render()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = grp,
    buffer = buf,
    callback = function()
      write_buf(buf)
    end,
  })
end

local function ensure_question_buf(name)
  local buf = buffer_for(name)
  if buf then
    return buf
  end
  vim.fn.mkdir(state.drafts_dir, "p")
  local path = draft_path(name)
  if vim.fn.filereadable(path) ~= 1 then
    write_file(path, "")
  end
  buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = true
  vim.bo[buf].filetype = "markdown"
  state.bufs[name] = buf
  setup_question_autocmds(name, buf)
  if status_of(name) == "committed" then
    vim.bo[buf].modifiable = false
  end
  return buf
end

--------------------------------------------------------------------------------
-- Panel / questions list UI
--------------------------------------------------------------------------------

local timer_hl_map = { [1] = "ExamTimerWarn", [2] = "ExamTimerOrange", [3] = "ExamTimerRed" }

local function timer_hl(od)
  if od <= 0 then
    return "ExamTimerOk"
  end
  return timer_hl_map[od_level(od, state.limit_sec, state.config.overdraft_thresholds)] or "ExamTimerOk"
end

local function progress()
  local total = #state.questions
  local committed = 0
  for _, q in ipairs(state.questions) do
    if status_of(q.name) == "committed" then
      committed = committed + 1
    end
  end
  return committed, total
end

local function timer_buttons()
  return {
    {
      label = state.running and state.texts.pause or state.texts.start,
      fn = function()
        if state.running then
          M.pause()
        else
          M.start()
        end
      end,
    },
  }
end

local function question_buttons(name)
  local st = name and status_of(name) or nil
  local empty = name == nil or not has_text(name)
  local committed = st == "committed"
  local skipped = st == "skipped"
  return {
    {
      label = state.texts.commit,
      enabled = name ~= nil and not committed and not empty,
      fn = function()
        apply_status(name, "committed", true, "committed")
      end,
    },
    {
      label = state.texts.uncommit,
      enabled = committed,
      fn = function()
        apply_status(name, nil, false, "started")
      end,
    },
    {
      label = state.texts.skip,
      enabled = name ~= nil and not skipped and not committed and empty,
      fn = function()
        apply_status(name, "skipped", false, "skipped")
      end,
    },
    {
      label = state.texts.unskip,
      enabled = skipped,
      fn = function()
        apply_status(name, nil, false, "not_started")
      end,
    },
  }
end

local function buttons_line(list)
  local parts, ranges, col = {}, {}, 1
  for _, b in ipairs(list) do
    local text = "[ " .. b.label .. " ]"
    parts[#parts + 1] = text
    ranges[#ranges + 1] = { s = col, e = col + #text - 1, fn = b.fn, enabled = b.enabled ~= false }
    col = col + #text + 1
  end
  return table.concat(parts, " "), ranges
end

local function question_list_line(q)
  local suffix = ""
  if state.config.show_recommended and q.recommended > 0 then
    suffix = string.format(" (%d%s)", q.recommended, state.texts.minutes_short)
  end
  return q.name .. suffix, status_of(q.name)
end

local function set_buf_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function apply_lines(buf, lines, hls)
  set_buf_lines(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, state.ns, 0, -1)
  for _, h in ipairs(hls) do
    if h.virt then
      pcall(vim.api.nvim_buf_set_extmark, buf, state.ns, h.line - 1, 0, {
        virt_lines = { { { h.text, h.grp } } },
        virt_lines_above = true,
      })
    else
      local s = (h.s or 1) - 1
      local e = h.e or #lines[h.line]
      pcall(vim.api.nvim_buf_set_extmark, buf, state.ns, h.line - 1, s, {
        end_col = e,
        hl_group = h.grp,
        hl_eol = true,
        priority = 100,
      })
    end
  end
end

local function sidebar_label(i, q)
  return string.format("%d. %s", i, q.name)
end

local function sidebar_width()
  local w = 4
  for i, q in ipairs(state.questions) do
    w = math.max(w, vim.fn.strdisplaywidth(sidebar_label(i, q)))
  end
  return w + 2
end

-- Sidebar: question number + identifier; section separators are drawn as virtual
-- lines so they are neither cursorable nor counted by motions.
local function build_sidebar()
  local lines, actions, hls = {}, {}, {}
  local avail = panel_width(state.sidebar_win)
  local rule = string.rep("\u{2500}", math.max(1, sidebar_width() - 1))
  for i, q in ipairs(state.questions) do
    lines[#lines + 1] = clip_display(sidebar_label(i, q), avail)
    actions[#lines] = { type = "question", name = q.name }
    hls[#hls + 1] = { line = #lines, grp = question_hl(q.name) }
    if q.new_section and i > 1 then
      hls[#hls + 1] = { line = #lines, virt = true, grp = "ExamRule", text = rule }
    end
  end
  if #lines == 0 then
    lines = { "" }
  end
  return lines, actions, hls
end

-- Full questions buffer: each question followed by its own action buttons.
local function build_questions()
  local lines, actions, hls, buttons = {}, {}, {}, {}
  local hide = state.config.hide_list_before_start and not state.started_once
  if hide then
    lines[1] = (state.config.hide_list_message ~= "" and state.config.hide_list_message) or "..."
    return lines, actions, hls, buttons
  end
  for _, q in ipairs(state.questions) do
    if q.new_section then
      lines[#lines + 1] = q.section
      hls[#hls + 1] = { line = #lines, grp = "ExamSection" }
    end
    local text = question_list_line(q)
    lines[#lines + 1] = text
    actions[#lines] = { type = "question", name = q.name }
    hls[#hls + 1] = { line = #lines, grp = question_hl(q.name) }
    local bl, ranges = buttons_line(question_buttons(q.name))
    lines[#lines + 1] = bl
    local btn_line = #lines
    for _, r in ipairs(ranges) do
      r.line = btn_line
      buttons[#buttons + 1] = r
      hls[#hls + 1] = { line = btn_line, s = r.s, e = r.e, grp = r.enabled and "ExamButton" or "ExamButtonDisabled" }
    end
  end
  return lines, actions, hls, buttons
end

local function commit_render(buf, lines, hls, actions, buttons)
  apply_lines(buf, lines, hls)
  state.actions[buf] = actions or {}
  state.buttons[buf] = buttons or {}
end

-- Real text width of a panel window (window frame minus the number/sign/
-- statuscolumn gutter). This is the width lines must fit into.
function panel_width(win)
  if win_ok(win) then
    local info = vim.fn.getwininfo(win)[1]
    if info then
      return math.max(1, info.width - info.textoff)
    end
    return math.max(1, vim.api.nvim_win_get_width(win))
  end
  return vim.o.columns
end

-- Truncate a string to at most `width` display columns.
function clip_display(s, width)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(s) <= width then
    return s
  end
  local out, w, i = {}, 0, 0
  while true do
    local ch = vim.fn.strcharpart(s, i, 1)
    if ch == "" then
      break
    end
    local cw = vim.fn.strdisplaywidth(ch)
    if w + cw > width then
      break
    end
    out[#out + 1] = ch
    w = w + cw
    i = i + 1
  end
  return table.concat(out)
end

-- Flatten a possibly multi-line value into a single line (strip, headings).
local function inline_text(s)
  return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Wrap text to `width` display columns, preserving blank lines (paragraphs).
local function wrap_display(s, width)
  width = math.max(1, width)
  local lines = {}
  for _, para in ipairs(vim.split(s, "\n", { plain = true })) do
    if para == "" then
      lines[#lines + 1] = ""
    else
      local cur = ""
      for word in para:gmatch("%S+") do
        while vim.fn.strdisplaywidth(word) > width do
          local head = clip_display(word, width)
          lines[#lines + 1] = cur == "" and head or (cur .. " " .. head)
          cur = ""
          word = word:sub(#head + 1)
        end
        local cand = cur == "" and word or (cur .. " " .. word)
        if vim.fn.strdisplaywidth(cand) <= width then
          cur = cand
        else
          if cur ~= "" then
            lines[#lines + 1] = cur
          end
          cur = word
        end
      end
      lines[#lines + 1] = cur
    end
  end
  if #lines == 0 then
    lines = { "" }
  end
  return lines
end

-- Keep only as many trailing segments as fit into `budget` characters; the
-- first segment is truncated as a last resort. Returns the kept segments.
local function fit_segments(segs, budget)
  local kept = {}
  local n = 0
  for _, s in ipairs(segs) do
    kept[#kept + 1] = s
    n = n + #s.text
  end
  while #kept > 1 and n > budget do
    n = n - #kept[#kept].text
    kept[#kept] = nil
  end
  if n > budget and #kept == 1 then
    kept[1].text = vim.fn.strcharpart(kept[1].text, 0, math.max(0, budget))
  end
  return kept
end

-- Timer strip: warning left-aligned, timing info and button right-aligned. The
-- line is always trimmed to exactly the window width, so it can never scroll
-- horizontally (which used to push the warning out of view).
local function render_timer()
  if not buf_ok(state.timer_buf) then
    return
  end
  local width = math.max(1, panel_width(state.timer_win) - 1)
  local left = ""
  if not state.running then
    left = state.started_once and state.texts.paused or state.texts.before_start
  end

  local el = exam_elapsed()
  local od = el - state.limit_sec
  local segs = {
    { text = state.texts.time .. " " .. fmt_time(el) .. " / " .. fmt_time(state.limit_sec), grp = timer_hl(od) },
  }
  if od > 0 then
    segs[#segs + 1] = { text = "   +" .. fmt_time(od), grp = timer_hl(od) }
  end
  if state.current then
    local q = state.questions[state.order[state.current]]
    local txt = "   " .. state.current .. " " .. fmt_time(q_elapsed(state.current))
    if state.config.show_recommended and q and q.recommended > 0 then
      txt = txt .. " / " .. fmt_time(q.recommended * 60)
    end
    segs[#segs + 1] = { text = txt }
  end
  local committed, total = progress()
  segs[#segs + 1] = { text = string.format("   %d/%d", committed, total) }

  local bl, ranges = buttons_line(timer_buttons())
  local gap = "   "
  local budget = math.max(0, width - #left - #gap - #bl - 1)
  local info, info_hls, col = "", {}, 0
  for _, s in ipairs(fit_segments(segs, budget)) do
    local from = col + 1
    info = info .. s.text
    col = col + #s.text
    if s.grp and #s.text > 0 then
      info_hls[#info_hls + 1] = { s = from, e = col, grp = s.grp }
    end
  end
  local pad = math.max(0, width - #left - #info - #gap - #bl)
  local base = #left + pad
  local btn_shift = base + #info + #gap
  local hls, buttons = {}, {}
  if #left > 0 then
    hls[#hls + 1] = { line = 1, s = 1, e = #left, grp = "ExamTimerWarn" }
  end
  for _, h in ipairs(info_hls) do
    h.line = 1
    h.s = h.s + base
    h.e = h.e + base
    hls[#hls + 1] = h
  end
  for _, r in ipairs(ranges) do
    r.line = 1
    r.s = r.s + btn_shift
    r.e = r.e + btn_shift
    buttons[#buttons + 1] = r
    hls[#hls + 1] = { line = 1, s = r.s, e = r.e, grp = r.enabled and "ExamButton" or "ExamButtonDisabled" }
  end
  commit_render(state.timer_buf, { left .. string.rep(" ", pad) .. info .. gap .. bl }, hls, {}, buttons)
end

local function render_strip()
  if not buf_ok(state.strip_buf) then
    return
  end
  local avail = panel_width(state.strip_win)
  local bl, ranges = buttons_line(question_buttons(state.current))
  bl = clip_display(bl, avail)
  local hls, buttons = {}, {}
  for _, r in ipairs(ranges) do
    if r.e <= avail then
      r.line = 1
      buttons[#buttons + 1] = r
      hls[#hls + 1] = { line = 1, s = r.s, e = r.e, grp = r.enabled and "ExamButton" or "ExamButtonDisabled" }
    end
  end
  local lines = { bl }
  if state.current then
    local q = state.questions[state.order[state.current]]
    local wrapped = wrap_display((q and q.text) or "", avail)
    local first = clip_display(state.current .. ". " .. wrapped[1], avail)
    lines[#lines + 1] = first
    local name_len = math.min(#state.current, #first)
    if name_len > 0 then
      hls[#hls + 1] = { line = #lines, s = 1, e = name_len, grp = question_hl(state.current) }
    end
    local text_start = #state.current + 3
    if #first >= text_start then
      hls[#hls + 1] = { line = #lines, s = text_start, e = #first, grp = "ExamQuestionText" }
    end
    for k = 2, #wrapped do
      local line = clip_display(wrapped[k], avail)
      lines[#lines + 1] = line
      if #line > 0 then
        hls[#hls + 1] = { line = #lines, s = 1, e = #line, grp = "ExamQuestionText" }
      end
    end
  else
    lines[#lines + 1] = ""
  end
  commit_render(state.strip_buf, lines, hls, {}, buttons)
  if win_ok(state.strip_win) then
    vim.api.nvim_win_set_height(state.strip_win, math.max(2, math.min(#lines, math.floor(vim.o.lines / 3))))
  end
end

local function render_sidebar()
  if not buf_ok(state.sidebar_buf) then
    return
  end
  local lines, actions, hls = build_sidebar()
  commit_render(state.sidebar_buf, lines, hls, actions)
end

local function render_questions(buf)
  local lines, actions, hls, buttons = build_questions()
  commit_render(buf, lines, hls, actions, buttons)
end

function M.render()
  if not state.active then
    return
  end
  render_timer()
  render_strip()
  render_sidebar()
  if buf_ok(state.ql_buf) and win_ok(state.main_win) and vim.api.nvim_win_get_buf(state.main_win) == state.ql_buf then
    render_questions(state.ql_buf)
  end
end

--------------------------------------------------------------------------------
-- Mouse / key interaction
--------------------------------------------------------------------------------

local function buf_action(buf, line, col)
  local btns = state.buttons[buf]
  if btns and col then
    for _, b in ipairs(btns) do
      if b.line == line and col >= b.s and col <= b.e then
        if b.enabled ~= false then
          b.fn()
        end
        return
      end
    end
  end
  local a = state.actions[buf] and state.actions[buf][line]
  if a and a.type == "question" then
    M.open_question(a.name)
  end
end

local function is_button_line(buf, line)
  for _, b in ipairs(state.buttons[buf] or {}) do
    if b.line == line then
      return true
    end
  end
  return false
end

local function on_click()
  local m = vim.fn.getmousepos()
  if not win_ok(m.winid) then
    return
  end
  -- A buffer-local <LeftMouse> mapping replaces Vim's built-in handling, which
  -- normally focuses the clicked window. Do it explicitly (at least for the main
  -- window) so clicking back from an aux panel actually switches focus.
  if m.winid == state.main_win then
    vim.api.nvim_set_current_win(state.main_win)
  end
  buf_action(vim.api.nvim_win_get_buf(m.winid), m.line, m.column)
  if win_ok(m.winid) then
    vim.api.nvim_win_call(m.winid, function()
      local view = vim.fn.winsaveview()
      view.leftcol = 0
      vim.fn.winrestview(view)
    end)
  end
end

local function on_enter()
  local buf = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  buf_action(buf, pos[1], pos[2] + 1)
end

local function create_scratch()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.keymap.set("n", "<LeftMouse>", on_click, { buffer = buf, silent = true })
  vim.keymap.set("n", "<CR>", on_enter, { buffer = buf, silent = true })
  return buf
end

local function style_aux_win(win, opts)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  -- A global 'sidescrolloff' forces horizontal scrolling to keep N columns to
  -- the right of the cursor, which makes narrow panels scroll even on short
  -- lines; 'virtualedit' lets the cursor go past end-of-line (scroll too).
  vim.wo[win].sidescrolloff = 0
  pcall(function()
    vim.wo[win].virtualedit = "none"
  end)
  -- 'statuscolumn' (and friends) can add a hidden gutter that makes the text
  -- area narrower than nvim_win_get_width(); clear it so the panels line up.
  pcall(function()
    vim.wo[win].statuscolumn = ""
  end)
  -- Hide the statusline/winbar for the panel windows only, so the user's own
  -- statusline (e.g. lualine) is untouched in the main window.
  vim.wo[win].statusline = " "
  vim.wo[win].winbar = ""
  if opts and opts.winfixwidth then
    vim.wo[win].winfixwidth = true
  end
  if opts and opts.winfixheight then
    vim.wo[win].winfixheight = true
  end
end

local function ensure_ui_buffers()
  if not buf_ok(state.timer_buf) then
    state.timer_buf = create_scratch()
  end
  if not buf_ok(state.sidebar_buf) then
    state.sidebar_buf = create_scratch()
  end
  if not buf_ok(state.strip_buf) then
    state.strip_buf = create_scratch()
  end
end

-- Layout:
--   [ timer (full width) ]
--   [ sidebar | strip    ]
--   [ sidebar | main     ]
local function layout_ui()
  if not win_ok(state.main_win) then
    state.main_win = vim.api.nvim_get_current_win()
  end
  ensure_ui_buffers()
  if not win_ok(state.timer_win) then
    state.timer_win = vim.api.nvim_open_win(state.timer_buf, false, { split = "above", win = state.main_win, height = 1 })
    style_aux_win(state.timer_win, { winfixheight = true })
  end
  if not win_ok(state.sidebar_win) then
    state.sidebar_win = vim.api.nvim_open_win(state.sidebar_buf, false, { split = "left", win = state.main_win })
    style_aux_win(state.sidebar_win, { winfixwidth = true })
    -- Style first (number/signcolumn off), then size, so the width equals the
    -- text width and labels never overflow into horizontal scrolling.
    vim.api.nvim_win_set_width(state.sidebar_win, sidebar_width())
  end
  if not win_ok(state.strip_win) then
    state.strip_win = vim.api.nvim_open_win(state.strip_buf, false, { split = "above", win = state.main_win, height = 2 })
    style_aux_win(state.strip_win)
  end
  if buf_ok(state.ql_buf) and vim.api.nvim_win_get_buf(state.main_win) == state.ql_buf then
    vim.wo[state.main_win].statusline = " "
  end
end

local function close_ui()
  for _, w in ipairs({ state.strip_win, state.sidebar_win, state.timer_win }) do
    if win_ok(w) then
      vim.api.nvim_win_close(w, true)
    end
  end
  state.strip_win, state.sidebar_win, state.timer_win = nil, nil, nil
  if win_ok(state.main_win) then
    vim.wo[state.main_win].statusline = ""
  end
end

function M.toggle_ui()
  if win_ok(state.timer_win) or win_ok(state.sidebar_win) or win_ok(state.strip_win) then
    close_ui()
  else
    layout_ui()
    M.render()
  end
end

-- Show the questions list in the main window (replacing the question buffer).
function M.open_questions()
  if not state.active then
    notify("No active exam", vim.log.levels.WARN)
    return
  end
  if not buf_ok(state.ql_buf) then
    state.ql_buf = create_scratch()
  end
  if not win_ok(state.main_win) then
    state.main_win = vim.api.nvim_get_current_win()
  end
  render_questions(state.ql_buf)
  vim.api.nvim_win_set_buf(state.main_win, state.ql_buf)
  vim.api.nvim_set_current_win(state.main_win)
  -- The questions list is a special buffer: hide the statusline for it.
  vim.wo[state.main_win].statusline = " "
end

--------------------------------------------------------------------------------
-- Navigation helpers (bound by the user)
--------------------------------------------------------------------------------

local function require_exam_buffer()
  local buf = vim.api.nvim_get_current_buf()
  if not (state.actions[buf] or state.buttons[buf]) then
    notify("No active exam", vim.log.levels.WARN)
    return nil
  end
  return buf
end

local function find_question(step)
  local buf = require_exam_buffer()
  if not buf then
    return
  end
  local l = vim.api.nvim_win_get_cursor(0)[1]
  local i = l + step
  while i >= 1 and i <= vim.api.nvim_buf_line_count(buf) do
    local a = state.actions[buf][i]
    if a and a.type == "question" then
      M.open_question(a.name)
      return
    end
    i = i + step
  end
  notify(step > 0 and "No next question" or "No previous question", vim.log.levels.WARN)
end

function M.questions.find_next()
  find_question(1)
end

function M.questions.find_prev()
  find_question(-1)
end

local function move_interactive(step)
  local buf = require_exam_buffer()
  if not buf then
    return
  end
  local l = vim.api.nvim_win_get_cursor(0)[1]
  local i = l + step
  while i >= 1 and i <= vim.api.nvim_buf_line_count(buf) do
    if (state.actions[buf][i] ~= nil) or is_button_line(buf, i) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
    i = i + step
  end
end

function M.questions.next_button()
  move_interactive(1)
end

function M.questions.prev_button()
  move_interactive(-1)
end

--------------------------------------------------------------------------------
-- Exam actions
--------------------------------------------------------------------------------

local function require_active()
  if not state.active then
    notify("No active exam", vim.log.levels.WARN)
    return false
  end
  return true
end

function M.start()
  if not require_active() or state.running then
    return
  end
  local now = os.time()
  state.running = true
  state.active_since = now
  state.q_since = state.current and now or nil
  log_event(state.started_once and "resume" or "start")
  state.started_once = true
  M.render()
end

function M.pause()
  if not state.running then
    return
  end
  accrue(state, os.time())
  state.running = false
  state.active_since = nil
  state.q_since = nil
  log_event("pause")
  M.render()
end

function M.open_question(name)
  if not require_active() then
    return
  end
  if type(name) == "string" then
    name = vim.trim(name)
  end
  if not state.order[name] then
    notify("Unknown question: " .. tostring(name), vim.log.levels.WARN)
    return
  end
  local buf = ensure_question_buf(name)
  enter_question(name)
  if win_ok(state.main_win) then
    vim.api.nvim_win_set_buf(state.main_win, buf)
    vim.api.nvim_set_current_win(state.main_win)
    -- Restore the user's own statusline (e.g. lualine) for answer buffers.
    vim.wo[state.main_win].statusline = ""
  else
    vim.api.nvim_set_current_buf(buf)
    state.main_win = vim.api.nvim_get_current_win()
  end
  M.render()
end

local function focus_step(delta)
  if not require_active() then
    return
  end
  local n = #state.questions
  local i = state.order[state.current or ""] or (delta > 0 and 0 or 1)
  i = ((i - 1 + delta) % n) + 1
  M.open_question(state.questions[i].name)
end

function M.focus_next()
  focus_step(1)
end

function M.focus_prev()
  focus_step(-1)
end

local function set_read_only(name, ro)
  local buf = buffer_for(name)
  if buf then
    vim.bo[buf].modifiable = not ro
  end
end

-- Set a question's status, logging and applying read-only in one place.
apply_status = function(name, new_status, ro, log_status)
  if not require_active() or not name then
    return
  end
  if new_status == "committed" then
    write_buf(buffer_for(name))
  end
  state.statuses[name] = new_status
  log_event("status_set", { name = name, status = log_status })
  set_read_only(name, ro)
  save_state()
  M.render()
end

function M.commit()
  apply_status(state.current, "committed", true, "committed")
end

function M.uncommit()
  apply_status(state.current, nil, false, "started")
end

function M.skip()
  if not require_active() or not state.current then
    return
  end
  if has_text(state.current) then
    notify("Question is not empty", vim.log.levels.WARN)
    return
  end
  apply_status(state.current, "skipped", false, "skipped")
end

function M.unskip()
  apply_status(state.current, nil, false, "not_started")
end

--------------------------------------------------------------------------------
-- Export
--------------------------------------------------------------------------------

local function fmt_meta(date, limit_min, total_sec, od_sec)
  local parts = {
    string.format("%s: %s", state.texts.export_exam, state.title),
    string.format("%s: %s", state.texts.export_date, date),
    string.format("%s: %d %s", state.texts.export_limit, limit_min, state.texts.minutes),
    string.format("%s: %s", state.texts.export_total, fmt_time(total_sec)),
  }
  if od_sec and od_sec > 0 then
    parts[#parts + 1] = string.format("%s: +%s", state.texts.export_overdraft, fmt_time(od_sec))
  end
  return table.concat(parts, " \u{00b7} ")
end

local function build_section(heading, rows, date, total_sec, od_sec, body_rows)
  body_rows = body_rows or rows
  local out = {
    "## " .. heading,
    "",
    fmt_meta(date, state.manifest.time_minutes, total_sec, od_sec),
    "",
    "| Name | Section | Time |",
    "| ---- | ------- | ---- |",
  }
  for _, r in ipairs(rows) do
    out[#out + 1] = string.format("| %s | %s | %s |", r.name, r.section, fmt_time(r.time))
  end
  out[#out + 1] = ""
  local last
  for _, r in ipairs(body_rows) do
    if r.section ~= last then
      out[#out + 1] = "### " .. r.section
      out[#out + 1] = ""
      last = r.section
    end
    out[#out + 1] = string.format("#### %s. %s", r.name, inline_text(r.text or ""))
    out[#out + 1] = ""
    out[#out + 1] = (r.body and r.body:match("%S")) and r.body or state.texts.export_skipped
    out[#out + 1] = ""
  end
  return out
end

local function build_export()
  local snap = read_snapshot()
  local od = exam_elapsed() - state.limit_sec
  local current = rows_from(state.questions)
  local before_rows, before_total, before_date
  if snap then
    before_rows = snap.questions or {}
    before_total = snap.elapsed
    before_date = snap.date
  else
    before_rows = current
    before_total = exam_elapsed()
    before_date = os.date("%Y-%m-%d")
  end
  local out = {}
  vim.list_extend(out, build_section(state.texts.export_before, before_rows, before_date, before_total, nil))
  if snap and od > 0 then
    local prev, prev_time = {}, {}
    for _, r in ipairs(before_rows) do
      prev[r.name] = r.body or ""
      prev_time[r.name] = r.time or 0
    end
    local changed, overdraft_rows = {}, {}
    for _, r in ipairs(current) do
      if (r.body or "") ~= prev[r.name] then
        changed[#changed + 1] = r
      end
      -- Time spent on the question after the boundary, whether or not it changed.
      local d = (r.time or 0) - (prev_time[r.name] or 0)
      if d > 0 then
        overdraft_rows[#overdraft_rows + 1] = { name = r.name, section = r.section, text = r.text, time = d, body = r.body }
      end
    end
    if #overdraft_rows > 0 or #changed > 0 then
      vim.list_extend(
        out,
        build_section(state.texts.export_after, overdraft_rows, os.date("%Y-%m-%d"), exam_elapsed(), od, changed)
      )
    end
  end
  return out
end

local function do_export(file)
  local out = build_export()
  if not write_file(file, table.concat(out, "\n") .. "\n") then
    notify("Cannot write file: " .. tostring(file), vim.log.levels.ERROR)
    return
  end
  log_event("export", { file = file })
  notify("Exported: " .. file)
end

function M.export(file)
  if not require_active() then
    return
  end
  do_export(file)
end

function M.export_and_pause(file)
  if not require_active() then
    return
  end
  do_export(file)
  M.pause()
end

--------------------------------------------------------------------------------
-- Run / setup
--------------------------------------------------------------------------------

local function start_timer_loop()
  if state.timer then
    return
  end
  state.timer = vim.uv.new_timer()
  state.timer:start(0, 1000, vim.schedule_wrap(function()
    if not state.active then
      return
    end
    check_overdraft()
    M.render()
  end))
end

local function bootstrap(dir, manifest)
  local initial_buf = vim.api.nvim_get_current_buf()
  state.dir = dir
  state.drafts_dir = dir .. "/drafts"
  vim.fn.mkdir(state.drafts_dir, "p")

  if not manifest then
    local content = read_file(dir .. "/exam.yaml")
    if not content then
      error("exam.nvim: cannot read " .. dir .. "/exam.yaml", 0)
    end
    manifest = load_manifest(content)
  end
  state.manifest = manifest
  state.config = vim.tbl_deep_extend("force", defaults, state.user_config or {}, manifest.options or {})
  state.texts = vim.tbl_deep_extend("force", texts_mod.TEXTS, state.config.texts or {})
  state.title = manifest.title
  state.limit_sec = manifest.time_minutes * 60

  state.statuses = {}
  state.bufs = {}
  state.actions = {}
  state.buttons = {}
  apply_highlights(state.config.highlights)
  flatten_questions(manifest)
  load_state_json()
  reconstruct()
  state.snapshot_written = read_snapshot() ~= nil

  state.active = true
  ensure_mouse()
  layout_ui()
  M.open_questions()
  -- Drop the startup "[No Name]" buffer if it is empty and untouched, so it
  -- does not linger in the buffer list after the exam UI takes over.
  if
    buf_ok(initial_buf)
    and initial_buf ~= state.ql_buf
    and vim.bo[initial_buf].buftype == ""
    and not vim.bo[initial_buf].modified
    and vim.api.nvim_buf_get_name(initial_buf) == ""
  then
    pcall(vim.api.nvim_buf_delete, initial_buf, {})
  end
  start_timer_loop()
end

function M.run(args)
  local parts = vim.split(args or "", "%s+", { trimempty = true })
  local name, path = parts[1], parts[2]
  if not name or name == "" then
    notify("Usage: :ExamRun <name> [path]", vim.log.levels.ERROR)
    return
  end
  if state.active then
    notify("An exam is already active in this session", vim.log.levels.WARN)
    return
  end
  local dir = exam_dir(name)
  local existing = vim.fn.filereadable(dir .. "/exam.yaml") == 1
  local manifest
  if not existing then
    if not path then
      notify("A manifest path is required for a new exam", vim.log.levels.ERROR)
      return
    end
    local content = read_file(path)
    if not content then
      notify("Cannot read manifest: " .. path, vim.log.levels.ERROR)
      return
    end
    manifest = load_manifest(content) -- validate before copying (fails loudly)
    vim.fn.mkdir(dir, "p")
    write_file(dir .. "/exam.yaml", content)
    log_event_at(dir, "session_start", { name = name })
  elseif path then
    notify("Ignoring path: resuming an existing exam", vim.log.levels.WARN)
  end
  bootstrap(dir, manifest)
end

function M.setup(opts)
  state.user_config = vim.tbl_deep_extend("force", state.user_config or {}, opts or {})
  state.texts = vim.tbl_deep_extend("force", texts_mod.TEXTS, state.user_config.texts or {})
  ensure_mouse()
  apply_highlights((state.config and state.config.highlights) or state.user_config.highlights or {})
  return M
end

local exam_group = vim.api.nvim_create_augroup("Exam", { clear = true })

-- Panels must never stay horizontally scrolled (that hides left-anchored text
-- such as the "not started" warning). Snapping leftcol back does not move the
-- cursor, so buttons stay reachable with both keyboard and mouse.
local function is_aux_win(w)
  return w ~= nil and (w == state.timer_win or w == state.sidebar_win or w == state.strip_win)
end

local function reset_leftcol(w)
  if not win_ok(w) then
    return
  end
  vim.api.nvim_win_call(w, function()
    local v = vim.fn.winsaveview()
    if v.leftcol ~= 0 then
      v.leftcol = 0
      vim.fn.winrestview(v)
    end
  end)
end

vim.api.nvim_create_autocmd("WinScrolled", {
  group = exam_group,
  callback = function()
    if state.active then
      reset_leftcol(vim.v.event and vim.v.event.winid)
    end
  end,
})

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
  group = exam_group,
  callback = function()
    if not state.active then
      return
    end
    local w = vim.api.nvim_get_current_win()
    if is_aux_win(w) then
      reset_leftcol(w)
    end
  end,
})

vim.api.nvim_create_autocmd("VimResized", {
  group = exam_group,
  callback = function()
    if not state.active then
      return
    end
    if win_ok(state.sidebar_win) then
      vim.api.nvim_win_set_width(state.sidebar_win, sidebar_width())
    end
    if win_ok(state.timer_win) then
      vim.api.nvim_win_set_height(state.timer_win, 1)
    end
    M.render() -- re-wrap the question text and resize the strip
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = exam_group,
  callback = function()
    if not state.active then
      return
    end
    for _, buf in pairs(state.bufs) do
      write_buf(buf)
    end
    log_event("close")
    save_state()
  end,
})

return M
