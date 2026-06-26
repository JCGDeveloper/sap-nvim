-- sap-nvim.core.inactive
-- Show and act on inactive ABAP objects from the system queue.

local M = {}

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function try_open_local(obj_name)
  local cwd = vim.fn.getcwd()
  local name = obj_name:lower()
  for _, ext in ipairs({ "abap", "cls", "intf", "prog", "ddls", "dcl" }) do
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

local function handle_single_object(obj)
  local obj_name = obj.name or tostring(obj)
  vim.ui.select(
    { "Open local file", "Activate in system", "Open + Activate" },
    { prompt = obj_name .. " — choose action:" },
    function(action)
      if not action then return end
      local open_it     = action == "Open local file"   or action == "Open + Activate"
      local activate_it = action == "Activate in system" or action == "Open + Activate"

      if open_it then
        if not try_open_local(obj_name) then
          notify("Local file not found for: " .. obj_name, vim.log.levels.WARN)
        end
      end
      if activate_it then
        require("sap-nvim.core.adt").activate_bulk({ obj })
      end
    end
  )
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

      local choices = { { name = "[Activate ALL (" .. #objects .. " objects)]", all = true } }
      for _, obj in ipairs(objects) do
        table.insert(choices, obj)
      end

      vim.ui.select(choices, {
        prompt = "Inactive objects — pick one to act on, or activate all:",
        format_item = function(item)
          if item.all then return item.name end
          return string.format("%s [%s]", item.name or "?", item.type or "?")
        end,
      }, function(choice)
        if not choice then return end

        if choice.all then
          require("sap-nvim.core.adt").activate_bulk(objects)
          return
        end

        handle_single_object(choice)
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
