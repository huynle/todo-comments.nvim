local Util = require("todo-comments.util")

--- @class TodoConfig
local M = {}

M.keywords = {}
M.keyword_regex = {}
M.keyword_ft = {}
M.keyword_glob = {}
--- @type TodoOptions
M.options = {}
M.loaded = false

M.ns = vim.api.nvim_create_namespace("todo-comments")

--- @class TodoOptions
-- TODO: add support for markdown todos
local defaults = {
  signs = true, -- show icons in the signs column
  sign_priority = 8, -- sign priority
  -- keywords recognized as todo comments
  keywords = {
    FIX = {
      icon = " ", -- icon used for the sign, and in search results
      color = "error", -- can be a hex color, or a named color (see below)
      alt = { "FIXME", "BUG", "FIXIT", "ISSUE" }, -- a set of other keywords that all map to this FIX keywords
      -- signs = false, -- configure signs for some keywords individually
    },
    TODO = { icon = " ", color = "info" },
    HACK = { icon = " ", color = "warning" },
    WARN = { icon = " ", color = "warning", alt = { "WARNING", "XXX" } },
    PERF = { icon = " ", alt = { "OPTIM", "PERFORMANCE", "OPTIMIZE" } },
    NOTE = { icon = " ", color = "hint", alt = { "INFO" } },
    TEST = { icon = "⏲ ", color = "test", alt = { "TESTING", "PASSED", "FAILED" } },
  },
  gui_style = {
    fg = "NONE", -- The gui style to use for the fg highlight group.
    bg = "BOLD", -- The gui style to use for the bg highlight group.
  },
  merge_keywords = true, -- when true, custom keywords will be merged with the defaults
  -- highlighting of the line containing the todo comment
  -- * before: highlights before the keyword (typically comment characters)
  -- * keyword: highlights of the keyword
  -- * after: highlights after the keyword (todo text)
  highlight = {
    multiline = true, -- enable multine todo comments
    multiline_pattern = "^.", -- lua pattern to match the next multiline from the start of the matched keyword
    multiline_context = 10, -- extra lines that will be re-evaluated when changing a line
    before = "", -- "fg" or "bg" or empty
    keyword = "wide", -- "fg", "bg", "wide" or empty. (wide is the same as bg, but will also highlight surrounding characters)
    after = "fg", -- "fg" or "bg" or empty
    -- pattern can be a string, or a table of regexes that will be checked
    pattern = [[.*<(KEYWORDS)\s*:]], -- pattern or table of patterns, used for highlightng (vim regex)
    -- pattern = { [[.*<(KEYWORDS)\s*:]], [[.*\@(KEYWORDS)\s*]] }, -- pattern used for highlightng (vim regex)
    comments_only = true, -- uses treesitter to match keywords in comments only
    max_line_len = 400, -- ignore lines longer than this
    exclude = {}, -- list of file types to exclude highlighting
    throttle = 200,
  },
  -- list of named colors where we try to extract the guifg from the
  -- list of hilight groups or use the hex color if hl not found as a fallback
  colors = {
    error = { "DiagnosticError", "ErrorMsg", "#DC2626" },
    warning = { "DiagnosticWarn", "WarningMsg", "#FBBF24" },
    info = { "DiagnosticInfo", "#2563EB" },
    hint = { "DiagnosticHint", "#10B981" },
    default = { "Identifier", "#7C3AED" },
    test = { "Identifier", "#FF00FF" },
  },
  search = {
    command = "rg",
    args = {
      "--color=never",
      "--no-heading",
      "--with-filename",
      "--line-number",
      "--column",
    },
    -- regex that will be used to match keywords.
    -- don't replace the (KEYWORDS) placeholder
    pattern = [[\b(KEYWORDS):]], -- ripgrep regex
    -- pattern = [[\b(KEYWORDS)\b]], -- match without the extra colon. You'll likely get false positives
  },
}

M._options = nil

function M.setup(options)
  if vim.fn.has("nvim-0.8.0") == 0 then
    error("todo-comments needs Neovim >= 0.8.0. Use the 'neovim-pre-0.8.0' branch for older versions")
  end
  M._options = options
  if vim.api.nvim_get_vvar("vim_did_enter") == 0 then
    vim.defer_fn(function()
      M._setup()
    end, 0)
  else
    M._setup()
  end
end

function M._setup()
  M.options = vim.tbl_deep_extend("force", {}, defaults, M.options or {}, M._options or {})

  -- -- keywords should always be fully overriden
  if M._options and M._options.keywords and M._options.merge_keywords == false then
    M.options.keywords = M._options.keywords
  end

  for kw, opts in pairs(M.options.keywords) do
    M.keywords[kw] = kw
    for idx, alt in pairs(opts.alt or {}) do
      local key_T = type(idx)
      local val_T = type(alt)
      if key_T == "string" and val_T == "table" then -- more stuff hidden
        M.keywords[idx] = kw
        M.keyword_ft[idx] = alt.ft or {}
        M.keyword_glob[idx] = alt.glob or {}
        if alt.regex then -- only add regex if it is available
          M.keyword_regex[idx] = alt.regex
        end
      elseif key_T == "number" and val_T == "string" then -- text string
        M.keywords[alt] = kw
        M.keyword_ft[alt] = {}
        M.keyword_glob[alt] = {}
      elseif key_T == "string" and val_T == "string" then -- regex string
        M.keywords[idx] = kw
        M.keyword_regex[idx] = alt
        M.keyword_ft[idx] = {}
        M.keyword_glob[idx] = {}
      else
      end
    end
  end

  local function tags(keywords, boundary1, boundary2)
    boundary1 = boundary1 or ""
    boundary2 = boundary2 or ""
    local kws_input = keywords or vim.tbl_keys(M.keywords)
    local kws = {}
    for _, kw in pairs(kws_input or {}) do
      local possible_regex = M.keyword_regex[kw]
      -- get the ft for each keyword
      if possible_regex then
        kws[kw] = possible_regex
      else
        kws[kw] = string.format([[%s%s:%s]], boundary1, kw, boundary2) -- add in vimgrep word boundary char `<`
      end
    end
    table.sort(kws, function(a, b)
      return #b < #a
    end)
    return kws
  end

  function M.search_regex(keywords)
    local kws = vim.tbl_values(tags(keywords, "\\b", "\\b"))
    return M.options.search.pattern:gsub("KEYWORDS", table.concat(kws, "|"))
  end

  function M.search_ft(keywords)
    local search_ft = {}
    for _, kw in ipairs(keywords) do
      for _, item in ipairs(M.keyword_ft[kw]) do
        table.insert(search_ft, item)
      end
    end
    if M.options.search.ft_pattern and next(search_ft) then
      local fts = {}
      for _, item in pairs(search_ft) do
        local formatted_ft = M.options.search.ft_pattern:gsub("FT", item)
        table.insert(fts, vim.split(formatted_ft, "[%s$,]+"))
      end
      return fts
    end
    return
  end

  function M.search_glob(keywords)
    local search_glob = {}
    for _, kw in ipairs(keywords) do
      for _, item in ipairs(M.keyword_glob[kw]) do
        table.insert(search_glob, item)
      end
    end
    if M.options.search.glob_pattern and next(search_glob) then
      local globs = {}
      for _, item in pairs(search_glob) do
        local formatted_glob = M.options.search.glob_pattern:gsub("GLOB", item)
        table.insert(globs, vim.split(formatted_glob, "[%s$,]+"))
      end
      return globs
    end
    return
  end

  M.hl_regex = {}
  local patterns = M.options.highlight.pattern
  patterns = type(patterns) == "table" and patterns or { patterns }

  for kw, regex in pairs(tags(nil, "<", ">")) do
    -- for kw, regex in pairs(tags(nil)) do
    for _, p in pairs(patterns) do
      p = p:gsub("KEYWORDS", regex)
      M.hl_regex[kw] = p
    end
  end
  M.colors()
  M.signs()
  -- require("todo-comments.highlight").start()
  M.loaded = true
end

function M.signs()
  for kw, opts in pairs(M.options.keywords) do
    vim.fn.sign_define("todo-sign-" .. kw, {
      text = opts.icon,
      texthl = "TodoSign" .. kw,
    })
  end
end

function M.colors()
  local normal = Util.get_hl("Normal")
  local fg_dark = Util.is_dark(normal.foreground or "#ffffff") and normal.foreground or normal.background
  local fg_light = Util.is_dark(normal.foreground or "#ffffff") and normal.background or normal.foreground
  fg_dark = fg_dark or "#000000"
  fg_light = fg_light or "#ffffff"
  local fg_gui = M.options.gui_style.fg
  local bg_gui = M.options.gui_style.bg

  local sign_hl = Util.get_hl("SignColumn")
  local sign_bg = (sign_hl and sign_hl.background) and sign_hl.background or "NONE"

  for kw, opts in pairs(M.options.keywords) do
    local kw_color = opts.color or "default"
    local hex

    if kw_color:sub(1, 1) == "#" then
      hex = kw_color
    else
      local colors = M.options.colors[kw_color]
      colors = type(colors) == "string" and { colors } or colors

      for _, color in pairs(colors) do
        if color:sub(1, 1) == "#" then
          hex = color
          break
        end
        local c = Util.get_hl(color)
        if c and c.foreground then
          hex = c.foreground
          break
        end
      end
    end
    if not hex then
      error("Todo: no color for " .. kw)
    end
    local fg = Util.is_dark(hex) and fg_light or fg_dark

    vim.cmd("hi def TodoBg" .. kw .. " guibg=" .. hex .. " guifg=" .. fg .. " gui=" .. bg_gui)
    vim.cmd("hi def TodoFg" .. kw .. " guibg=NONE guifg=" .. hex .. " gui=" .. fg_gui)
    vim.cmd("hi def TodoSign" .. kw .. " guibg=" .. sign_bg .. " guifg=" .. hex .. " gui=NONE")
  end
end

return M
