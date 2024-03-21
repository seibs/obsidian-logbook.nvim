local Obsidian = require("obsidian")
local Note = require("obsidian.note")
local Search = require("obsidian.search")


local M = {}

M.config = {}

function M.init()
end

function M.setup(config)
end

local function str_to_datetime(str)
    if str == nil or str == "" then
        return nil
    end
    local datetime_pattern = "(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d)%:(%d%d)";
    local y, m, d, h, mm = str:match(datetime_pattern);
    return os.time { year = y, month = m, day = d, hour = h, min = mm };
end

local function time_to_str(time)
    local formatted = "%Y-%m-%d %H:%M";
    return os.date(formatted, time)
end

Entry = { clock_in = nil, clock_out = nil };

function Entry:new(clock_in, clock_out)
    local obj = {
        clock_in = clock_in or os.time(),
        clock_out = clock_out,
    };
    setmetatable(obj, self);
    self.__index = self;
    return obj;
end

function Entry:from_str(entry_str)
    local entry_pattern = "^%[(.*)%]%-%-%[?(.*)%]?";
    local in_str, out_str = entry_str:match(entry_pattern);
    return Entry:new(str_to_datetime(in_str), str_to_datetime(out_str));
end

function Entry:to_string()
    local entry_str = "";
    if self.clock_in ~= nil then
        entry_str = entry_str .. "[" .. time_to_str(self.clock_in) .. "]--";
    else
        return nil
    end
    if self.clock_out ~= nil then
        entry_str = entry_str .. "[" .. time_to_str(self.clock_out) .. "]";
    end
    return entry_str;
end

NoteFile = { path = nil, bufnr = nil }

function NoteFile:new(path, bufnr)
    local obj = {
        path = path,
        bufnr = bufnr,
    };
    setmetatable(obj, self);
    self.__index = self;
    return obj;
end

local function is_clocked_in(note)
    local logbook = note:get_field("logbook") or {};
    for _, entry_str in ipairs(logbook) do
        local entry = Entry:from_str(entry_str);
        if entry.clock_in ~= nil and entry.clock_out == nil then
            -- Already clocked in to this note
            return true;
        end
    end
    return false;
end

local function merge_note_file_lists(primary, secondary)
    local result = {}
    local pathSet = {}

    -- Add entries from primary to result and path set
    for _, file in ipairs(primary) do
        result[file.path] = file
        pathSet[file.path] = true
    end

    -- Add entries from secondary to result if path is not in path set
    for _, file in ipairs(secondary) do
        if not pathSet[file.path] then
            result[file.path] = file
            pathSet[file.path] = true
        end
    end

    -- Convert result table to a list
    local finalList = {}
    for _, file in pairs(result) do
        table.insert(finalList, file)
    end

    return finalList
end

function M.find_clocked_in_files(client)
    local opts = client:_prepare_search_opts(nil, {})
    local term = [[\[.*\]--\"?$]];
    local iter = Search.search(client.dir, term, opts)

    local files = {}
    local match = iter();
    while match ~= nil do
        table.insert(files, NoteFile:new(match['path']['text']));
        match = iter()
    end
    return files
end

function M.find_clocked_in_modified_buffers(client)
    local client_dir = client.dir:resolve().filename
    local buffers = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.fn.getbufvar(bufnr, "&modified") == 1 then
            local path = vim.api.nvim_buf_get_name(bufnr);
            -- Only look at files within the vault
            -- TODO this will probably fail if a non-note from the vault is open
            print(vim.inspect(path))
            print(vim.inspect(client_dir))
            if string.sub(path, 1, string.len(client_dir)) == client_dir then
                local note = Note.from_buffer(bufnr)
                if is_clocked_in(note) then
                    table.insert(buffers, NoteFile:new(path, bufnr))
                end
            end
        end
    end
    return buffers
end

local function clock_out_note(note)
    local logbook = note:get_field("logbook") or {};
    local new_logbook = {};
    for _, entry_str in ipairs(logbook) do
        local entry = Entry:from_str(entry_str);
        if entry.clock_in ~= nil and entry.clock_out == nil then
            -- Already clocked in to this note, clock out
            entry.clock_out = os.time();
        end
        table.insert(new_logbook, entry:to_string());
    end
    note:add_field("logbook", new_logbook);
    return note
end

local function clock_out_path(path)
    local note = Note.from_file(path);
    note = clock_out_note(note);
    note:save(path);
    vim.cmd("checktime")
end

local function clock_out_buffer(bufnr)
    local note = Note.from_buffer(bufnr);
    note = clock_out_note(note);
    note:save_to_buffer({ bufnr = bufnr });
end

function M.clock_in()
    local bufnr = vim.api.nvim_get_current_buf()
    local note = Note.from_buffer(bufnr);
    if is_clocked_in(note) then
        -- Already clocked in to this note, nothing to do
        return
    end

    local successful_clockout = M.clock_out()
    if not successful_clockout then
        -- Something went wrong in clock out
        return
    end

    local logbook = note:get_field("logbook") or {};
    local new_entry = Entry:new();
    table.insert(logbook, new_entry:to_string());
    note:add_field("logbook", logbook);
    note:save_to_buffer({bufnr = bufnr});
end

function M.clock_out()
    local client = Obsidian.get_client();
    local clocked_in_files = M.find_clocked_in_files(client);
    local clocked_in_buffers = M.find_clocked_in_modified_buffers(client);

    local clocked_in_notes = merge_note_file_lists(clocked_in_buffers, clocked_in_files)
    if #clocked_in_notes > 1 then
        -- TODO Add in messaging about multiple clocked in files
        return false
    elseif #clocked_in_notes == 1 then
        local note_file = clocked_in_notes[1]
        if note_file.bufnr ~= nil then
            clock_out_buffer(note_file.bufnr)
        else
            clock_out_path(note_file.path)
        end
    end
    return true
end

return M
