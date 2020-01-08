local wallmaterial = settlements.wallmaterial
local half_map_chunk_size = settlements.half_map_chunk_size
local schematic_table = settlements.schematic_table

local c_air							= minetest.get_content_id("air")

local surface_mats = settlements.surface_materials

-------------------------------------------------------------------------------
-- function to fill empty space below baseplate when building on a hill
-------------------------------------------------------------------------------
local function ground(pos, data, va, c_shallow, c_deep) -- role model: Wendelsteinkircherl, Brannenburg
	--
	local p2 = vector.new(pos)
	local cnt = 0
	local mat = c_shallow
	p2.y = p2.y-1
	while true do
		cnt = cnt+1
		if cnt > 20 then break end
		if cnt > math.random(2,4) then mat = c_deep end
		local vi = va:index(p2.x, p2.y, p2.z)
		data[vi] = mat
		p2.y = p2.y-1
	end
end

-------------------------------------------------------------------------------
-- function clear space above baseplate 
-------------------------------------------------------------------------------
local function terraform(data, va, settlement_info)
	local c_air = minetest.get_content_id("air")
	local c_shallow = minetest.get_content_id(settlement_info.def.platform_shallow or "default:dirt")
	local c_deep = minetest.get_content_id(settlement_info.def.platform_deep or "default:stone")
	local fheight
	local fwidth
	local fdepth

	for i, built_house in ipairs(settlement_info) do
		local schematic_data = built_house.schematic_info
		local pos = settlement_info[i].pos
		if settlement_info[i].rotation == "0" or settlement_info[i].rotation == "180" 
		then
			fwidth = schematic_data.schematic.size.x
			fdepth = schematic_data.schematic.size.z
		else
			fwidth = schematic_data.schematic.size.z
			fdepth = schematic_data.schematic.size.x
		end
		fheight = schematic_data.schematic.size.y * 3 -- remove trees and leaves above
		--
		-- now that every info is available -> create platform and clear space above
		--
		for zi = 0,fdepth-1 do
			for yi = 0,fheight do
				for xi = 0,fwidth-1 do
					if yi == 0 then
						local p = {x=pos.x+xi, y=pos.y, z=pos.z+zi}
						ground(p, data, va, c_shallow, c_deep)
					else
						local vi = va:index(pos.x+xi, pos.y+yi, pos.z+zi)
						data[vi] = c_air
					end
				end
			end
		end
	end
end

local buildable_to_set
local buildable_to = function(c_node)
	if buildable_to_set then return buildable_to_set[c_node] end
	buildable_to_set = {}
	for k, v in pairs(minetest.registered_nodes) do
		if v.buildable_to then
			buildable_to_set[minetest.get_content_id(k)] = true
		end
	end
	
	-- TODO: some way to discriminate between settlement_defs? For now, apply ignore_materials universally.
	for _, def in pairs(settlements.settlement_defs) do
		if def.ignore_surface_materials then
			for _, ignore_material in ipairs(def.ignore_surface_materials) do
				buildable_to_set[minetest.get_content_id(ignore_material)] = true
			end
		end
	end
	
	return buildable_to_set[c_node]
end


-------------------------------------------------------------------------------
-- function to find surface block y coordinate
-------------------------------------------------------------------------------
local function find_surface(pos, data, va, altitude_min, altitude_max)
	if not va:containsp(pos) then return nil end
	
	local y = pos.y
	
	-- starting point for looking for surface
	local previous_vi = va:indexp(pos)
	local previous_node = data[previous_vi]
	local itter -- count up or down
	if buildable_to(previous_node) then
		itter = -1 -- going down
	else
		itter = 1 -- going up
	end
	for cnt = 0, 100 do
		local next_vi = previous_vi + va.ystride * itter
		y = y + itter
		if (altitude_min and altitude_min > y) or (altitude_max and altitude_max < y) then
			-- an altitude range was specified and we're outside it
			return nil
		end		
		if not va:containsi(next_vi) then return nil end
		local next_node = data[next_vi]
		if buildable_to(previous_node) ~= buildable_to(next_node) then
			--we transitioned through what may be a surface. Test if it was the right material.
			local above_node, below_node, above_vi, below_vi
			if itter > 0 then
				-- going up
				above_node, below_node = next_node, previous_node
				above_vi, below_vi = next_vi, previous_vi
			else
				above_node, below_node = previous_node, next_node
				above_vi, below_vi = previous_vi, next_vi
			end
			if surface_mats[below_node] then
				return va:position(below_vi), below_node
			else
				return nil
			end
		end
		previous_vi = next_vi
		previous_node = next_node
	end
	return nil
end

-------------------------------------------------------------------------------
-- check distance for new building
-------------------------------------------------------------------------------
local function check_distance(building_pos, building_size, settlement_info)
	local distance
	for i, built_house in ipairs(settlement_info) do
		distance = math.sqrt(
			((building_pos.x - built_house.pos.x)*(building_pos.x - built_house.pos.x))+
			((building_pos.z - built_house.pos.z)*(building_pos.z - built_house.pos.z)))
		if distance < building_size or 
		distance < built_house.schematic_info.hsize
		then
			return false
		end
	end
	return true
end


local function shallowCopy(original)
	local copy = {}
	for key, value in pairs(original) do
		copy[key] = value
	end
	return copy
end

-- randomize table
local function shuffle(tbl)
	local ret = shallowCopy(tbl)
	local size = #ret
	for i = size, 1, -1 do
		local rand = math.random(size)
		ret[i], ret[rand] = ret[rand], ret[i]
	end
	return ret
end


-------------------------------------------------------------------------------
-- everything necessary to pick a fitting next building
-------------------------------------------------------------------------------
local function pick_next_building(pos_surface, count_buildings, settlement_info, settlement_def)
	local number_of_buildings = settlement_info.number_of_buildings
	local randomized_schematic_table = shuffle(settlement_def.schematics)
	-- pick schematic
	local size = #randomized_schematic_table
	for i = size, 1, -1 do
		-- already enough buildings of that type?
		local current_schematic = randomized_schematic_table[i]
		local current_schematic_name = current_schematic.name
		count_buildings[current_schematic_name] = count_buildings[current_schematic_name] or 0
		if count_buildings[current_schematic_name] < current_schematic.max_num*number_of_buildings then
			-- check distance to other buildings
			local distance_to_other_buildings_ok = check_distance(pos_surface, 
				current_schematic.hsize,
				settlement_info)
			if distance_to_other_buildings_ok then
				-- count built houses
				count_buildings[current_schematic.name] = count_buildings[current_schematic.name] +1
				return current_schematic
			end
		end
	end
	return nil
end

-------------------------------------------------------------------------------
-- save list of generated settlements
-------------------------------------------------------------------------------
function settlements.settlements_save()
	local file = io.open(minetest.get_worldpath().."/settlements.txt", "w")
	if file then
		file:write(minetest.serialize(settlements.settlements_in_world))
		file:close()
	end
end

local building_counts = {}
local settlement_sizes = {}

-------------------------------------------------------------------------------
-- fill settlement_info with LVM
--------------------------------------------------------------------------------
local function create_site_plan(minp, maxp, data, va, surface_min, surface_max)
	local possible_rotations = {"0", "90", "180", "270"}
-- TODO an option here
--	local possible_wallmaterials = wallmaterial
--	local possible_wallmaterials = {wallmaterial[math.random(1,#wallmaterial)]}
	
	-- find center of chunk
	local center = {
		x=maxp.x-half_map_chunk_size, 
		y=maxp.y, 
		z=maxp.z-half_map_chunk_size
	} 
	-- find center_surface of chunk
	local center_surface, surface_material = find_surface(center, data, va)
	if not center_surface then
		return nil
	end
	
	-- get a list of all the settlement defs that can be made on this surface mat
	local material_defs = surface_mats[surface_material]
	local settlement_defs = {}
	-- cull out any that have altitude min/max set outside the range of the chunk
	for _, def in ipairs(material_defs) do
		if (not def.altitude_min or def.altitude_min < maxp.y) and
			(not def.altitude_max or def.altitude_max > minp.y) then
			table.insert(settlement_defs, def)
		end
	end
	-- Nothing to pick from
	if #settlement_defs == 0 then
		return nil
	end
	
	 -- pick one at random
	settlement_def = settlement_defs[math.random(1, #settlement_defs)]
	
	-- Get a name for the settlement.
	local name = settlement_def.generate_name(center)
	
	local min_number = settlement_def.building_count_min or 5
	local max_number = settlement_def.building_count_max or 25
	
	local settlement_info = {}
	settlement_info.def = settlement_def
	settlement_info.name = name
	local number_of_buildings = math.random(min_number, max_number)
	settlement_info.number_of_buildings = number_of_buildings
	
	local replacements = {}
	settlement_info.replacements = replacements
	if settlement_def.replacements then
		for original, replacement in pairs(settlement_def.replacements) do
			if type(replacement) == "table" then
				replacement = replacement[math.random(1, #replacement)]
			end
			replacements[original] = replacement
		end
	end

	-- debugging variable
	local count_buildings = {}
	
	-- first building is townhall in the center
	local townhall = settlement_def.schematics[1]
	local rotation = possible_rotations[ math.random( #possible_rotations ) ]
	-- add to settlement info table
	local number_built = 1
	settlement_info[number_built] = {
		pos = center_surface, 
		schematic_info = townhall,
		rotation = rotation,
		surface_mat = surface_material,
	}
	-- debugging variable
	building_counts[townhall.name] = (building_counts[townhall.name] or 0) + 1
	-- now some buildings around in a circle, radius = size of town center
	local x, z, r = center_surface.x, center_surface.z, townhall.hsize
	-- draw circles around center and increase radius by math.random(2,5)
	for circle = 1,20 do
		if number_built < number_of_buildings	then 
			-- set position on imaginary circle
			for angle_step = 0, 360, 15 do
				local angle = angle_step * math.pi / 180
				local ptx, ptz = x + r * math.cos( angle ), z + r * math.sin( angle )
				ptx = math.floor(ptx + 0.5) -- round
				ptz = math.floor(ptz + 0.5)
				local pos1 = { x=ptx, y=center_surface.y, z=ptz}

				local pos_surface, surface_material = find_surface(pos1, data, va, settlement_def.altitude_min, settlement_def.altitude_max)
				if pos_surface then
					local building_all_info = pick_next_building(pos_surface, count_buildings, settlement_info, settlement_def)
					
					-- TODO test if building fits inside va. Doesn't seem to be a problem for mapgen, but
					-- sometimes the debugging tool cuts buildings at the edges of town. Maybe expand the debugging
					-- tool's voxel area a bit instead?
					
					if building_all_info then
						rotation = possible_rotations[ math.random( #possible_rotations ) ]
						number_built = number_built + 1
						settlement_info[number_built] = {
							pos = pos_surface, 
							schematic_info = building_all_info,
							rotation = rotation,
							surface_mat = surface_material,
						}
						building_counts[building_all_info.name] = (building_counts[building_all_info.name] or 0) + 1
						if number_of_buildings == number_built 
						then
							break
						end
					end
				else
					break
				end
			end
			r = r + math.random(2,5)
		else
			break
		end
	end
	if settlements.debug then
		minetest.chat_send_all("built ".. number_built .. " out of " .. number_of_buildings)
	end
	-- debugging
	settlement_sizes[number_built] = (settlement_sizes[number_built] or 0) + 1
	
	if number_built == 1 then
		return nil
	end
	-- add settlement to list
	table.insert(settlements.settlements_in_world, 
		{pos=center_surface, name=name, discovered_by = {}})
	-- save list to file
	settlements.settlements_save()

	return settlement_info
end

--if settlements.debug then
	minetest.register_on_shutdown(function()
		minetest.debug(dump(building_counts))
		minetest.debug(dump(settlement_sizes))
	end)
--end

local function initialize_nodes(settlement_info)
	for i, built_house in ipairs(settlement_info) do
		local building_all_info = built_house.schematic_info

		local width = building_all_info.schematic.size.x
		local depth = building_all_info.schematic.size.z
		local height = building_all_info.schematic.size.y

		local p = built_house.pos
		for yi = 1,height do
			for xi = 0,width do
				for zi = 0,depth do
					local ptemp = {x=p.x+xi, y=p.y+yi, z=p.z+zi}
					local node = minetest.get_node(ptemp)
					local node_def = minetest.registered_nodes[node.name]
					if node_def.on_construct then
						node_def.on_construct(ptemp)
					end
					if built_house.schematic_info.initialize_node then
						built_house.schematic_info.initialize_node(ptemp, node, node_def, settlement_info)
					end
				end
			end
		end
	end
end

-- generate paths between buildings
local function paths(data, va, settlement_info)
	local c_gravel = minetest.get_content_id(settlement_info.def.path_material or "default:gravel")
	local starting_point
	local end_point
	local distance
	--for k,v in pairs(settlement_info) do
	starting_point = settlement_info[1].pos
	for i,built_house in ipairs(settlement_info) do

		end_point = built_house.pos
		if starting_point ~= end_point
		then
			-- loop until end_point is reached (distance == 0)
			while true do

				-- define surrounding pos to starting_point
				local north_p = {x=starting_point.x+1, y=starting_point.y, z=starting_point.z}
				local south_p = {x=starting_point.x-1, y=starting_point.y, z=starting_point.z}
				local west_p = {x=starting_point.x, y=starting_point.y, z=starting_point.z+1}
				local east_p = {x=starting_point.x, y=starting_point.y, z=starting_point.z-1}
				-- measure distance to end_point
				local dist_north_p_to_end = math.sqrt(
					((north_p.x - end_point.x)*(north_p.x - end_point.x))+
					((north_p.z - end_point.z)*(north_p.z - end_point.z))
				)
				local dist_south_p_to_end = math.sqrt(
					((south_p.x - end_point.x)*(south_p.x - end_point.x))+
					((south_p.z - end_point.z)*(south_p.z - end_point.z))
				)
				local dist_west_p_to_end = math.sqrt(
					((west_p.x - end_point.x)*(west_p.x - end_point.x))+
					((west_p.z - end_point.z)*(west_p.z - end_point.z))
				)
				local dist_east_p_to_end = math.sqrt(
					((east_p.x - end_point.x)*(east_p.x - end_point.x))+
					((east_p.z - end_point.z)*(east_p.z - end_point.z))
				)
				-- evaluate which pos is closer to the end_point
				if dist_north_p_to_end <= dist_south_p_to_end and
				dist_north_p_to_end <= dist_west_p_to_end and
				dist_north_p_to_end <= dist_east_p_to_end 
				then
					starting_point = north_p
					distance = dist_north_p_to_end

				elseif dist_south_p_to_end <= dist_north_p_to_end and
				dist_south_p_to_end <= dist_west_p_to_end and
				dist_south_p_to_end <= dist_east_p_to_end 
				then
					starting_point = south_p
					distance = dist_south_p_to_end

				elseif dist_west_p_to_end <= dist_north_p_to_end and
				dist_west_p_to_end <= dist_south_p_to_end and
				dist_west_p_to_end <= dist_east_p_to_end 
				then
					starting_point = west_p
					distance = dist_west_p_to_end

				elseif dist_east_p_to_end <= dist_north_p_to_end and
				dist_east_p_to_end <= dist_south_p_to_end and
				dist_east_p_to_end <= dist_west_p_to_end 
				then
					starting_point = east_p
					distance = dist_east_p_to_end
				end
				-- find surface of new starting point
				local surface_point, surface_mat = find_surface(starting_point, data, va)
				-- replace surface node with default:gravel 
				if surface_point
				then
					local vi = va:index(surface_point.x, surface_point.y, surface_point.z)
					data[vi] = c_gravel

					-- don't set y coordinate, surface might be too low or high
					starting_point.x = surface_point.x
					starting_point.z = surface_point.z
				end
				if distance <= 1 or
				starting_point == end_point
				then
					break
				end
			end
		end
	end
end

function settlements.place_building(vm, built_house, settlement_info)
	local building_all_info = built_house.schematic_info

	local pos = built_house.pos
	local rotation = built_house.rotation
	-- get building node material for better integration to surrounding
	local platform_material = built_house.surface_mat
	local platform_material_name = minetest.get_name_from_content_id(platform_material)

	local building_schematic = building_all_info.schematic
	local replacements = {}
	if building_all_info.replace_nodes and settlement_info.replacements then
		replacements = shallowCopy(settlement_info.replacements)
	end
	if settlement_info.def.replace_with_surface_material then
		replacements[settlement_info.def.replace_with_surface_material] = platform_material_name
	end
	
	if settlements.debug then
		minetest.chat_send_all("building " .. built_house.schematic_info.name .. " at " .. minetest.pos_to_string(pos))
	end
	minetest.place_schematic_on_vmanip(
		vm, 
		pos, 
		building_schematic, 
		rotation, 
		replacements,
		true)
end

local data = {} -- for better memory management, use externally-allocated buffer
settlements.generate_settlement_vm = function(vm, va, minp, maxp)
	vm:get_data(data)
	
	local settlement_info = create_site_plan(minp, maxp, data, va)
	if not settlement_info
	then
		return
	end

	-- evaluate settlement_info and prepare terrain
	terraform(data, va, settlement_info)

	-- evaluate settlement_info and build paths between buildings
	if settlement_info.def.path_material then
		paths(data, va, settlement_info)
	end

	-- evaluate settlement_info and place schematics
	vm:set_data(data)
	for _, built_house in ipairs(settlement_info) do
		settlements.place_building(vm, built_house, settlement_info)
	end
	vm:calc_lighting()
	vm:write_to_map()

	-- evaluate settlement_info and initialize furnaces and chests
	initialize_nodes(settlement_info)
end

-- on map generation, try to build a settlement
settlements.generate_settlement = function(minp, maxp)
	local vm = minetest.get_voxel_manip()
	local emin, emax = vm:read_from_map(minp, maxp)
	local va = VoxelArea:new{
		MinEdge = emin,
		MaxEdge = emax
	}
	
	settlements.generate_settlement_vm(vm, va, minp, maxp)
end