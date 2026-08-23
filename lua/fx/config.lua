local M = {
	fx_cmd = { "fx", "acp" },
	mode = "code",
	default_model = "deepseek/deepseek-v4-flash",
	permission = "yolo",
	context_limits = { skill_catalog_bytes = 0 },
	force_write_file = true, -- force write current file before sending to fx
	output = { width = 64, max_height = 14 }, -- float sizing, used by ui.lua
	spinner = { -- request-line spinner; bring your own frames
		frames = { "»  ", "»» ", "»»»", " »»", "  »", "  «", " ««", "«««", "«« ", "«  " },
		interval = 70,
	},
	border = "single", -- float border: single|rounded|double|solid|shadow|none
    agent_context = {
        cursor = {
            row_text = true,
            row_position = true,
            col_position = true,
            word = true,
            treesitter_node = {
                type = true,
                range = true,
                text = false,
                parent = true,
                scope = true,
                inject = true,
            }
        },
        visual_selection = {
            text = true,
            row_range = true,
            col_range = true,
            treesitter_nodes = {
                covering = true, -- smallest named node that spans the selection
                type = true,
                range = true,
                text = false,
                parent = true,
                scope = true,
                inject = true,
            }
        }
    },
}

--- Merge user options
---@param opts table? user config overrides
function M.setup(opts)
	-- mutate M in place: other modules hold a reference to this table
	for k, v in pairs(vim.tbl_deep_extend("force", M, opts or {})) do
		M[k] = v
	end
end

return M
