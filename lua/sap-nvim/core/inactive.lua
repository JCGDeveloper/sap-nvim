-- sap-nvim.core.inactive
-- Show and activate inactive ABAP objects from the system queue.

local M = {}

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function activate_all()
  notify("Activating all inactive objects...")
  local stderr = {}
  vim.fn.jobstart({ "sapcli", "activation", "activate", "inactiveobjects" }, {
    on_stderr = function(_, data)
      for _, l in ipairs(data) do
        if vim.trim(l) ~= "" then table.insert(stderr, l) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          notify("All inactive objects activated.")
        else
          local msg = #stderr > 0 and stderr[1] or "Activation failed."
          notify(msg, vim.log.levels.ERROR)
        end
      end)
    end,
  })
end

local function try_open_local(obj_name)
  local cwd = vim.fn.getcwd()
  local name = obj_name:lower()
  for _, ext in ipairs({ "abap", "cls", "intf", "prog" }) do
    local path = cwd .. "/" .. name .. "." .. ext
    local f = io.open(path, "r")
    if f then
      f:close()
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      return true
    end
  end
  return false
end

function M.show_inactive()
  if not require("sap-nvim.core.adt").is_configured() then
    notify("No SAP connection configured. Run :SapSetup first.", vim.log.levels.WARN)
    return
  end

  notify("Fetching inactive objects...")
  require("sap-nvim.core.adt").fetch_inactive_objects(function(objects, err)
    vim.schedule(function()
      if err then
        notify(err, vim.log.levels.ERROR)
        return
      end
      if not objects or #objects == 0 then
        notify("No inactive objects found.")
        return
      end

      local choices = { "[Activate all (" .. #objects .. ")]" }
      for _, obj in ipairs(objects) do
        table.insert(choices, obj)
      end

      vim.ui.select(choices, {
        prompt = "Inactive objects (" .. #objects .. ") — select to open, [Activate all] to activate:",
      }, function(choice)
        if not choice then return end
        if choice:match("^%[Activate all") then
          activate_all()
          return
        end
        -- sapcli output is typically "TYPE/NAME" or just "NAME"
        local obj_name = choice:match("/(.+)$") or choice
        obj_name = vim.trim(obj_name)
        if not try_open_local(obj_name) then
          notify("Local file not found for: " .. obj_name, vim.log.levels.WARN)
        end
      end)
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("SapInactive", function()
    M.show_inactive()
  end, { desc = "sap-nvim: Show inactive objects" })

  vim.keymap.set("n", "<leader>ai", M.show_inactive, { desc = "ABAP: Inactive objects" })
end

return M
