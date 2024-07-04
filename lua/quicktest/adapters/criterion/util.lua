local meson = require("quicktest.adapters.criterion.meson")

local M = {}

---Split string on the given separator
---Copied from https://www.tutorialspoint.com/how-to-split-a-string-in-lua-programming
---@param inputstr string
---@param sep string
---@return string[]
function M.splitstr(inputstr, sep)
  if sep == nil then
    sep = "%s"
  end
  local t = {}
  for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
    table.insert(t, str)
  end
  return t
end

---@param result_json any
---@return string[]
function M.format_verbose(result_json)
  local formatted = {}

  table.insert(formatted, result_json["quicktest"]["name"])
  for _, ts in ipairs(result_json["test_suites"]) do
    table.insert(formatted, "  " .. ts["name"])
    for _, test in ipairs(ts["tests"]) do
      if test["status"] ~= "SKIPPED" then
        table.insert(formatted, "    " .. test["name"] .. ": " .. test["status"])
        if test["messages"] then
          for _, msg in ipairs(test["messages"]) do
            table.insert(formatted, "      " .. msg)
            table.insert(formatted, "")
          end
        end
      end
    end
  end
  return formatted
end

---@param result_json any
---@return string[]
function M.format_minimal(result_json)
  ---@class Error
  ---@field suite string
  ---@field name string
  ---@field messages string[]

  ---@type Error[]
  local errors = {}

  local formatted = {}
  local num_ok = 0
  local num_fail = 0
  local num_skip = 0

  for _, ts in ipairs(result_json["test_suites"]) do
    for _, test in ipairs(ts["tests"]) do
      if test["status"] == "PASSED" then
        num_ok = num_ok + 1
      elseif test["status"] == "FAILED" then
        num_fail = num_fail + 1
        if test["messages"] then
          ---@type Error
          local err = {
            suite = ts["name"],
            name = test["name"],
            messages = {},
          }
          for _, msg in ipairs(test["messages"]) do
            table.insert(err.messages, msg)
          end
          table.insert(errors, err)
        end
      else
        num_skip = num_skip + 1
      end
    end
  end

  table.insert(formatted, num_ok .. "/" .. num_ok + num_fail .. " OK (" .. result_json["quicktest"]["name"] .. ")")
  --
  -- if num_skip then
  --   table.insert(formatted, "SKIPPED: " .. num_skip)
  -- end
  --
  if num_fail then
    for i, err in ipairs(errors) do
      if i == 1 then
        table.insert(formatted, "")
      end
      table.insert(formatted, "FAILED: " .. err.suite .. "/" .. err.name)
      for _, msg in ipairs(err.messages) do
        table.insert(formatted, "  " .. msg)
      end
      table.insert(formatted, "")
    end
  end
  return formatted
end

---Prints the test results using the callback provided by the plugin
---@param result_json table
---@param send fun(data: any)
function M.print_results(result_json, send)
  local text = M.format_minimal(result_json)
  for _, value in ipairs(text) do
    send({ type = "stdout", output = value })
  end
end

---Get all error messages
---@param result_json table
---@return table
function M.get_error_messages(result_json)
  local errors = {}

  for _, ts in ipairs(result_json["test_suites"]) do
    for _, test in ipairs(ts["tests"]) do
      if test["status"] == "FAILED" and test["messages"] then
        for _, msg in ipairs(test["messages"]) do
          table.insert(errors, msg)
        end
      end
    end
  end
  return errors
end

---Get the filename of a C source file by removing the path
---@param path string path/to/file.c
---@return string
function M.get_filename(path)
  return path:match("[^/]*.c$")
end

---Uses meson introspect CLI to find the name of the test executable using the path of the file that is open in the given buffer
---Meson will output a JSON document with the name of all executables and sources used to build them, among other information.
---We want to find a test executable that uses the source file that is open in the given buffer.
---@note This function finds the first match. There is nothing preventing someone from using the same source file in multiple test exectuables,
---so that is a known limitation and is currently not handled.
---@param bufnr integer
---@param builddir string
---@return string
function M.get_test_exe_from_buffer(bufnr, builddir)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local targets = meson.get_targets(builddir)
  for _, target in ipairs(targets) do
    -- print(vim.inspect(target["target_sources"]))
    for _, target_source in ipairs(target["target_sources"]) do
      -- print(vim.inspect(source))
      for _, source in ipairs(target_source["sources"]) do
        -- print(vim.inspect(source))
        if source == bufname then
          return target["name"]
        end
      end
    end
  end
  return ""
end

---@class CaptureContext
---@field read_json boolean State indicating opening bracket has been found and data should be added to the text field
---@field text string All json text OR the previous line when searching for the test name
---@field test_name string Name of the test (either paramter or read from data stream when running all tests in a project)

---This function is fed all output when calling "meson test" either on a single test executable or all tests in a project.
---The function tries  to capture a JSON-document in the stream and the name of the test if running all tests in the project.
---It searches for the opening and closing brackets both of which are assumed to be on new lines.
---This function assumes the pretty-printed JSON data as output from the criterion test exectuable when passed the '--json' argument
---The name of the test is not part of the json test report that is output by the criterion executable.
---Therefore, when running all tests in the project through "meson test", we need to search for name that corresponds to the output.
---When running all tests, a typical meson output will look like
---line 1: "1/1 <name> OK"
---line 2: "-----✀ ------
---line 3: { <--- beginning of json test report
---So in this case we look for the scissor symbol and parse the line that was read before it.
---Return true if JSON was successfully captured.
---@param data string
---@param ctx CaptureContext
---@param test_name string
---@return boolean, table | nil
function M.capture_results(ctx, data, test_name)
  local result = nil
  local done = false

  if test_name ~= "" then
    ctx.test_name = test_name
  end

  if not ctx.test_name and not ctx.read_json then
    if string.find(data, "✀ ") then
      local parts = M.splitstr(ctx.text, " ")
      ctx.test_name = parts[2]
    else
      ctx.text = data -- save this line, it might contain the name of the test
    end
  end

  if vim.startswith(data, "{") then
    ctx.read_json = true
    ctx.text = ""
  end

  if ctx.read_json then
    ctx.text = ctx.text .. data .. "\n"
  end

  if vim.startswith(data, "}") then
    ctx.read_json = false
    result = vim.json.decode(ctx.text)
    result["quicktest"] = { ["name"] = ctx.test_name }
    ctx.test_name = nil
    done = true
  end

  return done, result
end

return M
