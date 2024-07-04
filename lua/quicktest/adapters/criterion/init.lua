local Job = require("plenary.job")

local util = require("quicktest.adapters.criterion.util")
local meson = require("quicktest.adapters.criterion.meson")
local criterion = require("quicktest.adapters.criterion.criterion")

local ns = vim.api.nvim_create_namespace("quicktest-criterion")

---@class CriterionAdapterOptions
---@field builddir (fun(buf: integer): string)?
---@field additional_args (fun(buf: integer): string[])?

local M = {
  name = "criterion",
  test_results = {},
  ---@type CriterionAdapterOptions
  options = {},
}

---@class Test
---@field test_suite string
---@field test_name string

---@class CriterionTestParams
---@field test Test
---@field test_exe string
---@field bufnr integer
---@field cursor_pos integer[]
---@field builddir string
---@field is_run_all boolean

---@param bufnr integer
---@param cursor_pos integer[]
---@return CriterionTestParams | nil,  string | nil
M.build_file_run_params = function(bufnr, cursor_pos)
  local builddir = M.options.builddir and M.options.builddir(bufnr) or "build"
  local test_exe = util.get_test_exe_from_buffer(bufnr, builddir)

  if test_exe == "" then
    return nil, "No test executable was found in " .. builddir
  end

  return {
    test = {},
    test_exe = test_exe,
    bufnr = bufnr,
    cursor_pos = cursor_pos,
    builddir = builddir,
  },
    nil
end

---@param bufnr integer
---@param cursor_pos integer[]
---@return CriterionTestParams | nil,  string | nil
M.build_line_run_params = function(bufnr, cursor_pos)
  local line = criterion.get_nearest_test(bufnr, cursor_pos)

  if line == "" then
    return nil, "No test to run"
  end

  local builddir = M.options.builddir and M.options.builddir(bufnr) or "build"
  local test_exe = util.get_test_exe_from_buffer(bufnr, builddir)

  if test_exe == "" then
    return nil, "No test executable was found in " .. builddir
  end

  local test = criterion.get_test_suite_and_name(line)
  if test == nil then
    return nil, "Failed to parse test suite and name"
  end

  return {
    test = test,
    test_exe = test_exe,
    bufnr = bufnr,
    cursor_pos = cursor_pos,
    builddir = builddir,
  },
    nil
end

---@param bufnr integer
---@param cursor_pos integer[]
---@return CriterionTestParams | nil, string | nil
function M.build_all_run_params(bufnr, cursor_pos)
  return {
    test = {},
    test_exe = "",
    bufnr = bufnr,
    cursor_pos = cursor_pos,
    builddir = M.options.builddir and M.options.builddir(bufnr) or "build",
    is_run_all = true,
  },
    nil
end

--- Executes the test with the given parameters.
---@param params CriterionTestParams
---@param send fun(data: any)
---@return integer
M.run = function(params, send)
  -- Build the project so we can show potential build errors in the UI.
  -- Otherwise the test will fail silently-ish providing little insight to the user.
  local compile = meson.compile(params.builddir)

  if compile.return_val ~= 0 then
    for _, line in ipairs(compile.text) do
      send({ type = "stderr", output = line })
    end
    send({ type = "exit", code = compile.return_val })
    return -1
  end

  local capture = {}

  local criterion_args = table.concat(
    criterion.make_test_args(
      params.test.test_suite,
      params.test.test_name,
      M.options.additional_args and M.options.additional_args(params.bufnr) or {}
    ),
    " "
  )

  --- Run the tests
  local job = Job:new({
    command = "meson",
    args = { "test", params.test_exe, "-C", params.builddir, "-v", "--test-args=" .. criterion_args },
    on_stdout = function(_, data)
      local done, report = util.capture_results(capture, data, params.test_exe)
      if done and report then
        util.print_results(report, send)
        M.test_results = report
      end
    end,
    on_stderr = function(_, data)
      send({ type = "stderr", output = data })
    end,
    on_exit = function(_, return_val)
      send({ type = "exit", code = return_val })
    end,
  })

  job:start()
  return job.pid -- Return the process ID
end

--- Handles actions to take after the test run, based on the results.
---@param params CriterionTestParams
---@param results any
M.after_run = function(params, results)
  local diagnostics = {}
  if params.is_run_all then
    return
  end

  for _, error in ipairs(util.get_error_messages(M.test_results)) do
    local line_no = criterion.locate_error(error)
    if line_no then
      table.insert(diagnostics, {
        lnum = line_no - 1, -- lnum seems to be 0-based
        col = 0,
        severity = vim.diagnostic.severity.ERROR,
        message = "FAILED",
        source = "Test",
        user_data = "test",
      })
    end
  end

  vim.diagnostic.set(ns, params.bufnr, diagnostics, {})
end

--- Checks if the plugin is enabled for the given buffer.
---@param bufnr integer
---@return boolean
M.is_enabled = function(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local filename = util.get_filename(bufname)
  return vim.startswith(filename, "test_") and vim.endswith(filename, ".c")
end

---@param params CriterionTestParams
---@return string
M.title = function(params)
  if params.is_run_all then
    return "Running all tests from " .. params.builddir
  end

  local args = table.concat(
    criterion.make_test_args(
      params.test.test_suite,
      params.test.test_name,
      M.options.additional_args and M.options.additional_args(params.bufnr) or {}
    ),
    " "
  )

  return "Running " .. params.test_exe .. " " .. args
end

--- Adapter options
setmetatable(M, {
  ---@param opts CriterionAdapterOptions
  __call = function(_, opts)
    M.options = opts
    return M
  end,
})

return M
