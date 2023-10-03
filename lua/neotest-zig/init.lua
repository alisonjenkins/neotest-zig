local async = require("neotest.async")
local lib = require("neotest.lib")
local log = require("neotest-zig.log")

---@type neotest.Adapter
local M = {
	name = "neotest-zig",
	version = "v1.0.3",
}

M.root = lib.files.match_root_pattern("*.zig")

---@param tree neotest.Tree
---@param spec neotest.RunSpec
function M.get_test_node_by_runspec(tree, spec)
	for _, node in tree:iter_nodes() do
		local test_node = node:data()
		if test_node.path == spec.context.path and test_node.name == spec.context.name then
			return test_node
		end
	end
	return nil
end

function M.is_test_file(file_path)
	return vim.endswith(file_path, ".zig")
end

function M.get_strategy_config(strategy, python, python_script, args)
	local config = {
		dap = nil, -- TODO: Implement DAP support.
	}
	if config[strategy] then
		return config[strategy]()
	end
end

---@async
---@return neotest.Tree | nil
function M.discover_positions(path)
	local query = [[
		;;query
		(TestDecl
			(STRINGLITERALSINGLE) @test.name
		) @test.definition
	]]
	local positions = lib.treesitter.parse_positions(path, query, { nested_namespaces = true })
	return positions
end

---@param args neotest.RunArgs
---@return neotest.RunSpec | nil
function M.build_spec(args)
	local function get_script_path()
		local str = debug.getinfo(2, "S").source:sub(2)
		return str:match("(.*/)") or "./"
	end

	local tree = args.tree:data()

	if tree.type == "file" or tree.type == "dir" then
		vim.schedule(function()
			log.debug("Skipping", tree.path, "::", tree.name,
				"because it's a file or a dir, not a test.")
		end)
		return nil
	end


	vim.schedule(function()
		log.debug("Processing test ", tree.path, "::", tree.name)
	end)

	local test_results_path = async.fn.tempname()
	local test_output_path = async.fn.tempname()
	local zig_test_runner_path = vim.fn.resolve(get_script_path() .. "../../zig/neotest-runner.zig")
	local test_command = 'zig test "' .. tree.path .. '"' ..
	    ' --test-filter ' .. tree.name ..
	    ' --test-runner "' .. zig_test_runner_path .. '"' ..
	    ' --test-cmd-bin --test-cmd "' .. test_results_path .. '" 2> "' .. test_output_path .. '"'
	local run_spec = {
		command = test_command,
		context = {
			test_results_path = test_results_path,
			test_output_path = test_output_path,
			path = tree.path,
			name = tree.name,
		},
	}
	vim.schedule(function()
		log.debug("Generated run spec:", run_spec)
	end)
	return run_spec
end

---@async
---@param spec neotest.RunSpec
---@param _ neotest.StrategyResult
---@param tree neotest.Tree
---@return neotest.Result[]
function M.results(spec, _, tree)
	local results = {}
	local test_node = M.get_test_node_by_runspec(tree, spec)
	if test_node == nil then
		error("Could not find a test node for '" .. spec.context.path .. ":" .. spec.context.name .. "'")
	end

	local success_reading, test_output = pcall(lib.files.read, spec.context.test_output_path)
	if success_reading == false then
		error("Could not load test output file at path '" .. spec.context.test_output_path .. "'")
	end

	local success_reading, test_results_json = pcall(lib.files.read, spec.context.test_results_path)
	if success_reading == false then
		results[test_node.id] = {
			status = "failed",
			output = spec.context.test_output_path,
			short = "Test failed",
		}
		return results
	end
	local test_results = vim.json.decode(test_results_json)
	if test_results == nil then
		error("Could not parse test results file at path '" .. spec.context.test_results_path .. "'")
	end

	for _, result_table in ipairs(test_results) do
		results[test_node.id] = {
			status = result_table.status,
			output = spec.context.test_output_path,
			short = result_table.error_message,
			errors = {
				{
					message = result_table.error_message,
					line = result_table.line - 1
				}
			}
		}
		return results
	end

	results[test_node.id] = {
		status = "Skipped",
		output = spec.context.results_path,
		short = "No results found",
	}
	return results
end

M._enable_debug_log = function()
	log.new({
		use_console = true,
		use_file = true,
		level = "trace",
	}, true)
end

setmetatable(M, {
	__call = function(_, opts)
		return M.setup(opts)
	end,
})

M.setup = function(opts)
	opts = opts or {}
	fooo = opts
	if (opts.debug_log) then
		M._enable_debug_log()
	end

	log.debug("Setup successful, running version ", M.version)
	return M
end

return M