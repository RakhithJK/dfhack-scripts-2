-- manipulator

gui = require 'gui'
widgets = require 'gui.widgets'
utils = require 'utils'
enabler = df.global.enabler
gps = df.global.gps

args = {...}
iargs = utils.invert(args)
if iargs['--profile'] then
    PROFILE = true
elseif iargs['--no-profile'] then
    PROFILE = false
end

VERSION = '0.5'
PROFILE = PROFILE or false

if PROFILE then
    p_data = {}
    function p_start(name)
        p_data[name] = os.clock()
    end
    function p_end(name)
        if p_data[name] then
            print(('%.5f secs [%s]'):format(os.clock() - p_data[name], name))
        end
    end
    function p_call(name, func, ...)
        p_start(name)
        func(...)
        p_end(name)
    end
else
    function p_start() end
    function p_end() end
    function p_call(name, func, ...) func(...) end
end
p_start('parse')

m_module = m_module or {cache = {}, default_env = {}}
function m_module.load(name, opts)
    if not opts then opts = {} end
    if name:sub(-4) == '.lua' then
        name = name:sub(1, -5)
    end
    name = 'manipulator/' .. name
    p_start('load ' .. name)
    local path = dfhack.findScript(name)
    if not path and not opts.optional then
        error('Could not find script:' .. name)
    end
    local env = opts.env
    if not env then
        env = m_module.default_env
        clear_table(env)
        setmetatable(env, {__index = _ENV})
    end
    env.manipulator_module = true
    local f
    local cache = m_module.cache[name]
    if cache and path == cache.path and env == cache.env and cache.mtime == dfhack.filesystem.mtime(path) then
        f = cache.callback
    else
        f, err = loadfile(path, 't', env)
        if not f then
            error(('Could not load script "%s": %s'):format(name, err))
        end
        m_module.cache[name] = {
            path = path,
            mtime = dfhack.filesystem.mtime(path),
            callback = f,
            env = env
        }
    end
    f()
    p_end('load ' .. name)
    return env
end

m_module.load('grid-config', {env = _ENV})
m_module.load('utils', {env = _ENV})
batch_ops = m_module.load('gui/batch_ops').batch_ops

penarray = dfhack.penarray
if not penarray or iargs['--lua-penarray'] then
    penarray = m_module.load('penarray').penarray
end

p_start('validate columns')
for id, col in pairs(SKILL_COLUMNS) do
    check_nil(tonumber(col.group), ('Column %i: Invalid group ID: %s'):format(id, col.group))
    check_nil(tonumber(col.color), ('Column %i: Invalid color ID: %s'):format(id, col.color))
    col.profession = check_nil(df.profession[col.profession], ('Column %i: Unrecognized profession: %s'):format(id, col.profession))
    col.labor = check_nil(df.unit_labor[col.labor], ('Column %i: Unrecognized labor: %s'):format(id, col.labor))
    col.skill = check_nil(df.job_skill[col.skill], ('Column %i: Unrecognized skill: %s'):format(id, col.skill))
    if col.label == nil or type(col.label) ~= 'string' or #tostring(col.label) ~= 2 then
        qerror(('Column %i: Invalid label: %s'):format(id, col.label))
    end
    if col.special == nil then col.special = false end
end

for id, lvl in pairs(SKILL_LEVELS) do
    check_nil(lvl.name, ('Skill level %i: Missing name'):format(id))
    check_nil(tonumber(lvl.points), ('Skill level %i: Invalid points: %s'):format(id, lvl.points))
    lvl.abbr = tostring(check_nil(lvl.abbr, ('Skill level %i: Missing abbreviation'):format(id))):sub(0, 1)
end
p_end('validate columns')

default_columns = default_columns or 0

manipulator = defclass(manipulator, gui.FramedScreen)
manipulator.focus_path = 'manipulator'
manipulator.ATTRS = {
    frame_style = gui.BOUNDARY_FRAME,
    frame_inset = 1,
    top_margin = 2,
    bottom_margin = 2,
    left_margin = 2,
    right_margin = 2,
    list_top_margin = 3,
    list_bottom_margin = 7,
}

function manipulator:init(args)
    p_start('init')
    self.units = {}
    for i, u in pairs(args.units) do
        self.units[i + 1] = unit_wrapper(u)
    end
    self.unit_max = #self.units
    self.bounds = {}
    self.gframe = 0
    self.list_start = 1   -- unit index
    self.list_end = 1     -- unit index
    self.list_height = 1  -- list_end - list_start + 1
    self.list_idx = 1
    self.grid_start = 1   -- SKILL_COLUMNS index
    self.grid_end = 1     -- SKILL_COLUMNS index
    self.grid_width = 0   -- grid_end - grid_start + 1
    self.grid_idx = 1
    self.grid_rows = {}
    skill_cache:clear()
    p_start('init units')
    for idx, u in pairs(self.units) do
        self.grid_rows[u] = penarray.new(#SKILL_COLUMNS, 1)
        if u._native == args.selected then
            self.list_idx = idx
        end
        u.allow_edit = true
        if not dfhack.units.isOwnRace(u._native) or not dfhack.units.isOwnCiv(u._native) or
                u.flags1.dead or not df.profession.attrs[u.profession].can_assign_labor then
            u.allow_edit = false
        end
        u.legendary = false
        if u.status.current_soul then
            for _, unit_skill in pairs(u.status.current_soul.skills) do
                if unit_skill.rating >= 15 then
                    u.legendary = true
                    break
                end
            end
        end
        u.on_fire = false
        for i, stat in pairs(u.body.components.body_part_status) do
            if stat.on_fire then
                u.on_fire = true
                break
            end
        end
    end
    p_end('init units')
    self:draw_grid()
    self.all_columns = load_columns(self)
    self.columns = {}
    p_start('populate columns')
    for k, c in pairs(self.all_columns) do
        if c.default then table.insert(self.columns, c) end
        c:clear_cache()
        c:populate(self.units)
    end
    p_end('populate columns')
    if type(default_columns) ~= 'table' then
        default_columns = get_column_ids(self.columns)
    else
        self.columns = get_columns(self.all_columns, default_columns)
    end
    self:set_title('Manage Labors')
    p_end('init')
end

function manipulator:set_title(title)
    self.frame_title = 'Dwarf Manipulator - ' .. title
end

function manipulator:onRenderBody(p)
    p.clip_y2 = gps.dimy - 2  -- extend lower clip boundary by 1 row
    self.gframe = self.gframe + 1
    if self.gframe > enabler.gfps then self.gframe = 0 end
    self.blink_state = (self.gframe < enabler.gfps / 3)
    local col_start_x = {}
    local x = self.left_margin
    local y = self.top_margin
    for id, col in pairs(self.columns) do
        col_start_x[id] = x
        OutputString(COLOR_GREY, x, y, col.title)
        x = x + col.width + 1
    end
    local grid_start_x = x
    self.grid_start = math.max(1, self.grid_start)
    self.grid_width = gps.dimx - x - self.right_margin + 1
    self.grid_end = math.min(self.grid_start + self.grid_width - 1, #SKILL_COLUMNS)
    if self.grid_end > #SKILL_COLUMNS then
        self.grid_start = self.grid_start - (self.grid_end - #SKILL_COLUMNS)
        self.grid_end = #SKILL_COLUMNS
    end
    for i = self.grid_start, self.grid_end do
        local col = SKILL_COLUMNS[i]
        local fg = col.color
        local bg = COLOR_BLACK
        if i == self.grid_idx then
            fg = COLOR_BLACK
            bg = COLOR_GREY
        end
        OutputString({fg = fg, bg = bg}, x, 1, col.label:sub(1, 1))
        OutputString({fg = fg, bg = bg}, x, 2, col.label:sub(2, 2))
        x = x + 1
    end
    if gps.mouse_x >= grid_start_x and gps.mouse_y >= 1 and gps.mouse_y <= 2 then
        local caption = ''
        local col = SKILL_COLUMNS[gps.mouse_x - grid_start_x + self.grid_start]
        if col.labor ~= df.unit_labor.NONE then
            caption = df.unit_labor.attrs[col.labor].caption
        elseif col.skill ~= df.job_skill.NONE then
            caption = df.job_skill.attrs[col.skill].caption_noun
        end
        OutputString(COLOR_GREY, math.min(gps.mouse_x, gps.dimx - #caption - 1), 3, caption)
    end
    y = self.list_top_margin + 1
    self.list_end = self.list_start + math.min(self.unit_max - self.list_start, gps.dimy - self.list_bottom_margin - self.list_top_margin - 2)
    self.list_height = self.list_end - self.list_start + 1
    if self.list_idx > self.list_end then
        local d = self.list_idx - self.list_end
        self.list_start = self.list_start + d
        self.list_end = self.list_end + d
    elseif self.list_idx < self.list_start then
        local d = self.list_start - self.list_idx
        self.list_start = self.list_start - d
        self.list_end = self.list_end - d
    end
    for i = self.list_start, self.list_end do
        local unit = self.units[i]
        if unit.dirty then
            self:draw_unit_row(unit)
        end
        for id, col in pairs(self.columns) do
            x = col_start_x[id]
            local fg = col:lookup_color(unit)
            local bg = COLOR_BLACK
            local text = col:lookup(unit)
            if i == self.list_idx and col.highlight then
                bg = COLOR_GREY
                fg = COLOR_BLACK
                text = text .. (' '):rep(col.width - #text)
            end
            OutputString({fg = fg, bg = bg}, x, y, text)
        end
        self.grid_rows[unit]:draw(grid_start_x, self.list_top_margin + i - self.list_start + 1,
            gps.dimx - grid_start_x - 1, 1,
            self.grid_start - 1, 0)
        y = y + 1
        unit.dirty = false
    end
    local unit = self.units[self.list_idx]
    local col = SKILL_COLUMNS[self.grid_idx]
    p:pen{fg = COLOR_WHITE}
    p:seek(0, gps.dimy - self.list_bottom_margin - 1)
    p:string(dfhack.units.isMale(unit._native) and string.char(11) or string.char(12)):string(' ')
    local translated_name = dfhack.TranslateName(unit.name)
    p:string(translated_name)
    if #translated_name > 0 then
        p:string(', ')
    end
    p:string(dfhack.units.getProfessionName(unit._native)):string(': ')
    if col.skill == df.job_skill.NONE then
        if col.labor ~= df.unit_labor.NONE then
            p:string(df.unit_labor.attrs[col.labor].caption, {fg = COLOR_LIGHTBLUE}):string(' ')
        end
        p:string(unit.status.labors[col.labor] and 'Enabled' or 'Not Enabled', {fg = COLOR_LIGHTBLUE})
    else
        local skill = skill_cache:get(unit, col.skill)
        local lvl = skill.rating
        local prof = df.job_skill.attrs[col.skill].caption_noun
        p:string((lvl > 0 and SKILL_LEVELS[lvl].name or 'Not') .. ' ' .. prof, {fg = COLOR_LIGHTBLUE})
        if lvl < #SKILL_LEVELS then
            p:string(' '):string(('(%i/%i)'):format(skill.experience, SKILL_LEVELS[lvl > 0 and lvl or 1].points), {fg = COLOR_LIGHTBLUE})
        end
    end
    p:newline()
    p:key('SELECT'):string(': Toggle labor ')
    p:key('SELECT_ALL'):string(': Toggle group ')
    p:key('UNITJOB_VIEW'):string(': View Unit ')
    p:key('UNITJOB_ZOOM_CRE'):string(': Go to Unit')
    p:newline()
    p:key('SECONDSCROLL_UP'):key('SECONDSCROLL_DOWN'):string(': Sort by skill')
    p:newline()
    p:key('CUSTOM_X'):key('CUSTOM_SHIFT_X'):string(': Select ')
    p:key('CUSTOM_A'):key('CUSTOM_SHIFT_A'):string(': all/none, ')
    p:key('CUSTOM_B'):string(': Batch ')
    p:key('CUSTOM_E'):string(': Edit ')
    p:newline()
    p:key('CUSTOM_SHIFT_C'):string(': Columns ')
    self.bounds.grid = {grid_start_x, self.list_top_margin + 1, gps.dimx - 2, self.list_top_margin + self.list_height}
    self.bounds.grid_header = {self.bounds.grid[1], 1, self.bounds.grid[3], 2}
    self.bounds.columns = {}
    for id, col in pairs(self.columns) do
        self.bounds.columns[id] = {col_start_x[id], self.list_top_margin + 1,
            col_start_x[id] + col.width - 1, self.list_top_margin + self.list_height}
    end
end

function manipulator:update_grid_tile(x, y)
    if x == nil then x = self.grid_idx end
    if y == nil then y = self.list_idx end
    local unit = self.units[y]
    local fg = COLOR_WHITE
    local bg = COLOR_BLACK
    local c = string.char(0xFA)
    local skill = SKILL_COLUMNS[x].skill
    local labor = SKILL_COLUMNS[x].labor
    if skill ~= df.job_skill.NONE then
        local level = skill_cache:get(unit, skill).rating
        c = level > 0 and SKILL_LEVELS[level].abbr or '-'
    end
    if labor ~= df.unit_labor.NONE then
        if unit.status.labors[labor] then
            bg = COLOR_GREY
            if skill == df.job_skill.NONE then
                c = string.char(0xF9)
            end
        end
    else
        bg = COLOR_CYAN
    end
    if x == self.grid_idx and y == self.list_idx then
        fg = COLOR_LIGHTBLUE
    end
    self.grid_rows[unit]:set_tile(x - 1, 0, {fg = fg, bg = bg, ch = c})
end

function manipulator:update_unit_grid_tile(unit, x)
    for y, u in pairs(self.units) do
        if u == unit then
            self:update_grid_tile(x, y)
            return
        end
    end
    error('Could not find unit in unit list')
end

function manipulator:draw_grid()
    p_start('draw_grid')
    for y = 1, #self.units do
        for x = 1, #SKILL_COLUMNS do
            self:update_grid_tile(x, y)
        end
    end
    p_end('draw_grid')
end

function manipulator:draw_unit_row(unit)
    for x = 1, #SKILL_COLUMNS do
        self:update_unit_grid_tile(unit, x)
    end
end

function manipulator:update_viewport()
    if self.list_idx > self.list_end then
        self.list_start = self.list_idx - self.list_height + 1
    elseif self.list_idx < self.list_start then
        self.list_start = self.list_idx
    end
    if self.grid_idx > self.grid_end then
        self.grid_start = self.grid_idx - self.grid_width + 1
    elseif self.grid_idx < self.grid_start then
        self.grid_start = self.grid_idx
    end
end

function manipulator:onInput(keys)
    local cur_x = self.grid_idx
    local cur_y = self.list_idx
    local cur_unit = self.units[self.list_idx]
    local old_x = cur_x
    local old_y = cur_y
    local old_unit = cur_unit
    process_keys(keys)
    if keys.LEAVESCREEN then
        self:dismiss()
        return
    end
    if keys.CURSOR_UP or keys.CURSOR_DOWN or keys.CURSOR_UP_FAST or keys.CURSOR_DOWN_FAST then
        self.list_idx = scroll_index(self.list_idx,
            ((keys.CURSOR_UP or keys.CURSOR_UP_FAST) and -1 or 1)
            * ((keys.CURSOR_UP_FAST or keys.CURSOR_DOWN_FAST) and 10 or 1),
            1, self.unit_max
        )
        self:update_viewport()
    end
    if keys.CURSOR_LEFT or keys.CURSOR_RIGHT or keys.CURSOR_LEFT_FAST or keys.CURSOR_RIGHT_FAST then
        self.grid_idx = scroll_index(self.grid_idx,
            ((keys.CURSOR_LEFT or keys.CURSOR_LEFT_FAST) and -1 or 1)
            * ((keys.CURSOR_LEFT_FAST or keys.CURSOR_RIGHT_FAST) and 10 or 1),
            1, #SKILL_COLUMNS, {wrap = false}
        )
        self:update_viewport()
    end
    if keys.CURSOR_DOWN_Z then
        self:update_grid_tile()
        local newgroup = SKILL_COLUMNS[self.grid_idx].group + 1
        for i = self.grid_idx, #SKILL_COLUMNS do
            if SKILL_COLUMNS[i].group == newgroup then
                self.grid_idx = i
                self:update_grid_tile()
                self:update_viewport()
                break
            end
        end
    elseif keys.CURSOR_UP_Z then
        self:update_grid_tile()
        local newgroup = SKILL_COLUMNS[math.max(1, self.grid_idx - 1)].group
        while self.grid_idx > 1 and SKILL_COLUMNS[self.grid_idx - 1].group == newgroup do
            self.grid_idx = self.grid_idx - 1
        end
        self:update_grid_tile()
        self:update_viewport()
    end
    if keys.SELECT then
        self:toggle_labor(self.grid_idx, self.list_idx)
    elseif keys.SELECT_ALL then
        self:toggle_labor_group(self.grid_idx, self.list_idx)
    elseif keys.CUSTOM_SHIFT_C then
        manipulator_columns{parent = self}:show()
    elseif keys.UNITJOB_VIEW then
        self:view_unit(self.units[self.list_idx])
    elseif keys.UNITJOB_ZOOM_CRE then
        self:zoom_unit(self.units[self.list_idx])
    elseif keys.SECONDSCROLL_UP or keys.SECONDSCROLL_DOWN then
        self:sort_skill(SKILL_COLUMNS[self.grid_idx].skill, keys.SECONDSCROLL_UP)
        self:update_unit_grid_tile(old_unit, old_x)
    elseif keys.CUSTOM_X then
        self:selection_start(cur_unit)
    elseif keys.CUSTOM_SHIFT_X then
        self:selection_extend(cur_unit)
    elseif keys.CUSTOM_A or keys.CUSTOM_SHIFT_A then
        for i, u in pairs(self.units) do
            self:_select_unit(u, keys.CUSTOM_A)
        end
        self.selection_state = nil
    elseif keys.CUSTOM_E then
        batch_ops({units = {cur_unit}}):show()
    elseif keys.CUSTOM_B then
        local units = {}
        for _, u in pairs(self.units) do
            if u.selected then
                table.insert(units, u)
            end
        end
        batch_ops({units = units}):show()
    elseif keys._MOUSE_L or keys._MOUSE_R then
        self:onMouseInput(gps.mouse_x, gps.mouse_y,
            {left = keys._MOUSE_L, right = keys._MOUSE_R}, dfhack.internal.getModifiers())
    end
    self:update_grid_tile(old_x, old_y)
    self:update_grid_tile()
end

function manipulator:onMouseInput(x, y, buttons, mods)
    local old_grid_col = self.grid_idx
    local old_grid_row = self.list_idx
    local old_unit = self.units[old_grid_row]
    local grid_col = x - self.bounds.grid[1] + self.grid_start
    local grid_row = y - self.bounds.grid[2] + self.list_start
    if in_bounds(x, y, self.bounds.grid) then
        if buttons.left then
            if mods.shift then
                self:toggle_labor_group(grid_col, grid_row)
            else
                self:toggle_labor(grid_col, grid_row)
            end
        elseif buttons.right then
            self.grid_idx = grid_col
            self.list_idx = grid_row
            self:update_grid_tile(old_grid_col, old_grid_row)
            self:update_grid_tile()
        end
    elseif in_bounds(x, y, self.bounds.grid_header) then
        if buttons.right or mods.shift then
            self:sort_skill(SKILL_COLUMNS[grid_col].skill, false)
        else
            self:sort_skill(SKILL_COLUMNS[grid_col].skill, true)
        end
        self:update_unit_grid_tile(old_unit, old_grid_col)
    else
        for id, col in pairs(self.columns) do
            if in_bounds(x, y, self.bounds.columns[id]) then
                col.on_click(self.units[grid_row], buttons, mods)
            end
        end
    end
end

function manipulator:sort_skill(skill, descending)
    self.units = merge_sort(self.units, make_sort_order(sort.skill, descending, skill))
    self.selection_state = nil
end

function manipulator:set_labor(x, y, state)
    local unit = self.units[y] or error('Invalid unit ID: ' .. y)
    local labor = SKILL_COLUMNS[x].labor or error('Invalid column id: ' .. x)
    local function cb(unit, labor, state)
        self:update_unit_grid_tile(unit, labors.get_column_index(labor))
    end
    labors.set(unit, labor, state, cb)
end

function manipulator:toggle_labor(x, y)
    local col = SKILL_COLUMNS[x] or error('Invalid column ID: ' .. x)
    local unit = self.units[y] or error('Invalid unit ID: ' .. y)
    if not labors.valid(unit, col.labor) then return end
    self:set_labor(x, y, not unit.status.labors[col.labor])
end

function manipulator:toggle_labor_group(x, y)
    local col = SKILL_COLUMNS[x] or error('Invalid column ID: ' .. x)
    local unit = self.units[y] or error('Invalid unit ID: ' .. y)
    local labor = col.labor
    local group = col.group
    if not labors.valid(unit, labor) then return end
    local state = not unit.status.labors[labor]
    for x, col in pairs(SKILL_COLUMNS) do
        if col.group == group then
            self:set_labor(x, y, state)
        end
    end
end

function manipulator:parent_select_unit(unit)
    local parent = self._native.parent
    for id, u in pairs(parent.units[parent.page]) do
        if u == unit._native then
            parent.cursor_pos[parent.page] = id
            return true
        end
    end
    return false
end

function manipulator:view_unit(u)
    local parent = self._native.parent
    if self:parent_select_unit(u) then
        u.dirty = true
        gui.simulateInput(parent, {UNITJOB_VIEW = true})
    end
end

function manipulator:zoom_unit(u)
    local parent = self._native.parent
    if self:parent_select_unit(u) then
        gui.simulateInput(parent, {UNITJOB_ZOOM_CRE = true})
        self:dismiss()
    end
end

function manipulator:_unit_index(unit)
    for i, u in pairs(self.units) do
        if unit == u then
            return i
        end
    end
end

function manipulator:_select_unit(u, state)
    if state ~= u.selected and u.allow_edit then
        u.selected = state
        u.dirty = true
    end
end

function manipulator:selection_start(u)
    self.selection_state = {start = u, state = not u.selected}
    self:_select_unit(u, not u.selected)
end

function manipulator:selection_extend(u)
    if not self.selection_state then
        return self:selection_start(u)
    end
    for i in irange(self:_unit_index(self.selection_state.start), self:_unit_index(u)) do
        self:_select_unit(self.units[i], self.selection_state.state)
    end
end

function manipulator:onResize(...)
    self.super.onResize(self, ...)
end

function manipulator:onDismiss(...)
    default_columns = get_column_ids(self.columns)
    self.super.onDismiss(...)
end

function manipulator:onGetSelectedUnit()
    local u = self.units[self.list_idx]
    u.dirty = true
    return u._native
end

manipulator_columns = defclass(manipulator_columns, gui.FramedScreen)
manipulator_columns.ATTRS = {
    focus_path = 'manipulator/columns',
    frame_title = 'Dwarf Manipulator - Columns',
}

function manipulator_columns:init(args)
    self.parent = args.parent
    if getmetatable(self.parent) ~= manipulator then error('Invalid context') end
    self.columns = self.parent.columns
    self.all_columns = self.parent.all_columns
    self.col_idx = 1
    self.all_col_idx = 1
    self.cur_list = 1
end

function manipulator_columns:get_selection()
    if self.cur_list == 1 then
        return self.columns[self.col_idx]
    else
        return self.all_columns[self.all_col_idx]
    end
end

function manipulator_columns:onRenderBody(p)
    local x1 = 2
    local x2 = math.floor(gps.dimx / 2) - 1
    local x3 = gps.dimx - 2
    local y1 = 4
    local y2 = gps.dimy - 6
    OutputString(COLOR_GREY, x1, y1 - 2, "Drag column names or use arrow keys to move cursor")
    self.bounds = {x1 = x1, x2 = x2, x3 = x3, y1 = y1, y2 = y2}
    self.bounds.col1 = {x1, y1, x2, y1 + #self.columns - 1}
    self.bounds.col1_full = {x1, y1, x2, y2}
    self.bounds.col2 = {x2 + 1, y1, x3, y1 + #self.all_columns - 1}
    self.bounds.col2_full = {x2 + 1, y1, x3, y2}
    local y = y1
    for i = 1, #self.columns do
        if self.drag_y == y then y = y + 1 end
        OutputString((self.cur_list == 1 and i == self.col_idx and COLOR_LIGHTGREEN) or COLOR_GREEN,
            x1, y, self.columns[i].title:sub(1, x2 - x1 - 1))
        y = y + 1
    end
    for i = 1, #self.all_columns do
        OutputString((self.cur_list == 2 and i == self.all_col_idx and COLOR_YELLOW) or COLOR_BROWN,
            x2 + 1, y1 + i - 1, self.all_columns[i].title:sub(1, x3 - x2 - 1))
    end
    local col = self:get_selection()
    local c_color = self.cur_list == 1 and COLOR_WHITE or COLOR_DARKGREY
    local a_color = self.cur_list == 2 and COLOR_WHITE or COLOR_DARKGREY
    OutputKeyString(c_color, x1, y2 + 1, 'CURSOR_UP_FAST', 'Move up')
    OutputKeyString(c_color, x1, y2 + 2, 'CURSOR_DOWN_FAST', 'Move down')
    OutputKeyString(c_color, x1, y2 + 3, 'CUSTOM_R', 'Remove')
    OutputKeyString(a_color, x2 + 1, y2 + 1, 'CUSTOM_A', 'Add')
    if col then
        OutputString(COLOR_GREY, x1, y2 + 4, col.desc)
    end
    if enabler.mouse_lbut_down == 1 then
        self:handle_drag()
    elseif enabler.mouse_lbut_down == 0 and self.in_drag then
        self:handle_drop()
    end
end

function manipulator_columns:handle_drag()
    local x = gps.mouse_x
    local y = gps.mouse_y
    if not self.in_drag and (in_bounds(x, y, self.bounds.col1) or
            in_bounds(x, y, self.bounds.col2)) then
        self.in_drag = true
        self.drag_add = in_bounds(x, y, self.bounds.col2)
        local col_idx = y - self.bounds.y1 + 1
        local col_list = self.drag_add and self.all_columns or self.columns
        self.drag_text = col_list[col_idx].title
        if in_bounds(x, y, self.bounds.col1) then
            self.drag_column = table.remove(self.columns, col_idx)
            self.drag_dx = x - self.bounds.x1 - 1
        elseif self.drag_add then
            self.drag_column = self.all_columns[col_idx]
            self.drag_dx = x - self.bounds.x2 - 1
        end
        self.col_idx_old = self.col_idx
        self.col_idx = 0
    end
    if self.in_drag then
        if in_bounds(x, y, self.bounds.col1_full) then
            self.drag_y = y
        else
            self.drag_y = nil
        end
        local fg = in_bounds(x, y, self.bounds.col1_full) and COLOR_LIGHTGREEN or COLOR_YELLOW
        OutputString(fg, x - self.drag_dx, y, self.drag_text)
    end
end

function manipulator_columns:handle_drop()
    local x = gps.mouse_x
    local y = gps.mouse_y
    local col_idx = math.min(#self.columns + 1, y - self.bounds.y1 + 1)
    self.in_drag = false
    if in_bounds(x, y, self.bounds.col1_full) then
        table.insert(self.columns, col_idx, self.drag_column)
        self.col_idx = col_idx
    else
        self.col_idx = math.min(#self.columns, self.col_idx_old)
    end
    self.drag_column = nil
    self.drag_y = nil
end

function manipulator_columns:onInput(keys)
    process_keys(keys)
    if keys.LEAVESCREEN then
        self:dismiss()
        return
    elseif keys.CURSOR_LEFT or keys.CURSOR_RIGHT then
        self.cur_list = 3 - self.cur_list
    elseif keys.CURSOR_UP or keys.CURSOR_DOWN then
        if self.cur_list == 1 then
            self.col_idx = self.col_idx + (keys.CURSOR_UP and -1 or 1)
            if self.col_idx < 1 then
                self.col_idx = #self.columns
            elseif self.col_idx > #self.columns then
                self.col_idx = 1
            end
        else
            self.all_col_idx = self.all_col_idx + (keys.CURSOR_UP and -1 or 1)
            if self.all_col_idx < 1 then
                self.all_col_idx = #self.all_columns
            elseif self.all_col_idx > #self.all_columns then
                self.all_col_idx = 1
            end
        end
    end
    if self.cur_list == 1 then
        if keys.CURSOR_UP_FAST and self.col_idx > 1 then
            tmp = self.columns[self.col_idx - 1]
            self.columns[self.col_idx - 1] = self.columns[self.col_idx]
            self.columns[self.col_idx] = tmp
            self.col_idx = self.col_idx - 1
        elseif keys.CURSOR_DOWN_FAST and self.col_idx < #self.columns then
            tmp = self.columns[self.col_idx + 1]
            self.columns[self.col_idx + 1] = self.columns[self.col_idx]
            self.columns[self.col_idx] = tmp
            self.col_idx = self.col_idx + 1
        elseif keys.CUSTOM_R then
            table.remove(self.columns, self.col_idx)
            self.col_idx = math.min(self.col_idx, #self.columns)
        end
    else
        if keys.CUSTOM_A or keys.SELECT then
            table.insert(self.columns, self.col_idx + 1, self:get_selection())
            self.col_idx = self.col_idx + 1
        end
    end
    self.super.onInput(self, keys)
end

function main()
    local scr = dfhack.gui.getCurViewscreen()
    if df.viewscreen_unitlistst:is_instance(scr) then
        cur = manipulator{units = scr.units[scr.page], selected = scr.units[scr.page][scr.cursor_pos[scr.page]]}
        cur:show()
    else
        dfhack.printerr('Invalid context')
    end
end
p_end('parse')
p_call('main', main)
