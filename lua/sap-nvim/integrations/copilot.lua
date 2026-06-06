-- sap-nvim.integrations.copilot
-- ABAP-aware AI via GitHub Copilot + CopilotChat.nvim.
--
-- This is the COMPLIANCE-SAFE path for corporate environments: it uses your
-- company GitHub Copilot license — the same backend as the VSCode Copilot
-- extension (including Claude models if your org enables them). No source code
-- leaves the approved channel, unlike a direct external-API integration.
--
-- It is OFF by default. Enable it explicitly and add the plugins to your manager:
--
--   {
--     "JCGDeveloper/sap-nvim",
--     dependencies = {
--       "zbirenbaum/copilot.lua",
--       "CopilotC-Nvim/CopilotChat.nvim",
--     },
--     config = function()
--       require("sap-nvim").setup({ ai = "copilot" })
--     end,
--   }
--
-- Then authenticate once with :Copilot auth (uses your company GitHub login).

local M = {}

local ABAP_PROMPT = [[You are an expert ABAP / SAP S/4HANA / CDS pair programmer.
- Follow Clean ABAP. Prefer ABAP OO over procedural code.
- Use CDS views for data models and respect RAP patterns where relevant.
- When reviewing, flag performance issues (SELECT inside loops, missing WHERE/ORDER BY),
  naming-convention violations, and untested logic.
- Always show corrected ABAP with valid syntax and name the AUnit tests to run.]]

local function enabled(opts)
  return opts.ai == "copilot" or opts.copilot == true
end

function M.setup(opts)
  opts = opts or {}
  if not enabled(opts) then
    return
  end

  -- 1) Inline suggestions (copilot.lua) — optional, no-op if not installed.
  local ok_cop, copilot = pcall(require, "copilot")
  if ok_cop then
    copilot.setup(vim.tbl_deep_extend("force", {
      suggestion = { enabled = true, auto_trigger = true },
      panel = { enabled = true },
      filetypes = { abap = true, cds = true },
    }, opts.copilot_opts or {}))
  end

  -- 2) Chat / agent (CopilotChat.nvim) with an ABAP system prompt.
  local ok_chat, chat = pcall(require, "CopilotChat")
  if ok_chat then
    local chat_cfg = { system_prompt = ABAP_PROMPT }
    -- Only pin a model if the user asked for one (e.g. a Claude model the org
    -- enabled). Otherwise let CopilotChat use the org default.
    if opts.copilot_model then
      chat_cfg.model = opts.copilot_model
    end
    chat.setup(vim.tbl_deep_extend("force", chat_cfg, opts.copilotchat_opts or {}))

    local map = vim.keymap.set
    map({ "n", "v" }, "<leader>agc", "<cmd>CopilotChatToggle<CR>",  { desc = "AI: Chat (Copilot)" })
    map({ "n", "v" }, "<leader>age", "<cmd>CopilotChatExplain<CR>", { desc = "AI: Explain ABAP" })
    map({ "n", "v" }, "<leader>agr", "<cmd>CopilotChatReview<CR>",  { desc = "AI: Review ABAP" })
    map({ "n", "v" }, "<leader>agt", "<cmd>CopilotChatTests<CR>",   { desc = "AI: Generate AUnit tests" })
    map({ "n", "v" }, "<leader>agf", "<cmd>CopilotChatFix<CR>",     { desc = "AI: Fix ABAP" })
  end
end

return M
