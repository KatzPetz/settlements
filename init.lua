settlements = {}

settlements.half_map_chunk_size = 40

settlements.surface_materials = {}
settlements.settlement_defs = {}

-- Minimum distance between settlements
settlements.min_dist_settlements = tonumber(minetest.settings:get("settlements_minimum_distance_between_settlements")) or 500
-- maximum allowed difference in height for building a settlement
local max_height_difference = tonumber(minetest.settings:get("settlements_maximum_height_difference")) or 10

local modpath = minetest.get_modpath(minetest.get_current_modname())

dofile(modpath.."/persistence.lua")
dofile(modpath.."/buildings.lua")
dofile(modpath.."/hud.lua")
dofile(modpath.."/chatcommands.lua")
dofile(modpath.."/admin_tools.lua")

settlements.register_settlement = function(settlement_type_name, settlement_def)
	assert(not settlements.settlement_defs[settlement_type_name])
	settlement_def.name = settlement_type_name
	settlements.settlement_defs[settlement_type_name] = settlement_def
	for _, material in ipairs(settlement_def.surface_materials) do
		local c_mat = minetest.get_content_id(material)
		local material_list = settlements.surface_materials[c_mat] or {}
		settlements.surface_materials[c_mat] = material_list
		table.insert(material_list, settlement_def)
	end
end

-- Interconverting lua and mts formatted schematics
-- Useful for modders adding existing schematics that are in mts format
function settlements.convert_mts_to_lua(schem_path)
	local str = minetest.serialize_schematic(schem_path, "lua", {lua_use_comments = true})
	local file = io.open(schem_path:sub(1,-4).."lua", "w")
	file:write(str.."\nreturn schematic")
	file:close()
end

dofile(modpath.."/default_settlements.lua")

-------------------------------------------------------------------------------
-- check distance to other settlements
-------------------------------------------------------------------------------
local function check_distance_other_settlements(center_new_chunk)
	local min_edge = vector.subtract(center_new_chunk, settlements.min_dist_settlements)
	local max_edge = vector.add(center_new_chunk, settlements.min_dist_settlements)
	
	-- This gets all neighbors within a cube-shaped volume
	local neighbors = settlements.settlements_in_world:get_areas_in_area(min_edge, max_edge, true, true)

	-- Search through those to find any that are within a spherical volume
	for i, settlement in pairs(neighbors) do
		local distance = vector.distance(center_new_chunk, settlement.min)
		if distance < settlements.min_dist_settlements then
			return false
		end
	end	
	return true
end

-------------------------------------------------------------------------------
-- evaluate heightmap
-------------------------------------------------------------------------------
local function evaluate_heightmap(heightmap)
	-- max height and min height, initialize with impossible values for easier first time setting
	local max_y = -50000
	local min_y = 50000
	-- only evaluate the center square of heightmap 40 x 40
	local square_start = 1621
	local square_end = 1661
	for j = 1 , 40, 1 do
		for i = square_start, square_end, 1 do
			-- skip buggy heightmaps, return high value
			if heightmap[i] == -31000 or
			heightmap[i] == 31000
			then
				return max_height_difference + 1
			end
			if heightmap[i] < min_y
			then
				min_y = heightmap[i]
			end
			if heightmap[i] > max_y
			then
				max_y = heightmap[i]
			end
		end
		-- set next line
		square_start = square_start + 80
		square_end = square_end + 80
	end
	-- return the difference between highest and lowest pos in chunk
	local height_diff = max_y - min_y
	-- filter buggy heightmaps
	if height_diff <= 1
	then
		return max_height_difference + 1
	end
	return height_diff
end

local half_map_chunk_size = settlements.half_map_chunk_size

minetest.register_on_generated(function(minp, maxp)
	-- don't build settlement underground
	if maxp.y < -100 then
		return
	end
	
	local existing_settlements = settlements.settlements_in_world:get_areas_in_area(minp, maxp, true, false, true)
	local id, data = next(existing_settlements)
	if id ~= nil then
		-- There's already a settlement in this chunk despite us being in mapgen.
		-- This chunk must have been previously generated and is now being re-generated. Override
		-- any further checks and try building a settlement here.
		local vm, emin, emax = minetest.get_mapgen_object("voxelmanip")
		local va = VoxelArea:new{MinEdge=emin, MaxEdge=emax}
		data = minetest.deserialize(data.data)
		settlements.generate_settlement_vm(vm, va, minp, maxp, data.name)
		return
	end

	-- don't build settlements too close to each other
	local center_of_chunk = vector.subtract(maxp, half_map_chunk_size)
	local dist_ok = check_distance_other_settlements(center_of_chunk)
	if dist_ok == false
	then
		return
	end

	-- don't build settlements on (too) uneven terrain
	local heightmap = minetest.get_mapgen_object("heightmap")
	local height_difference = evaluate_heightmap(heightmap)
	if height_difference > max_height_difference
	then
		return
	end
	
	local vm, emin, emax = minetest.get_mapgen_object("voxelmanip")
	local va = VoxelArea:new{MinEdge=emin, MaxEdge=emax}

	settlements.generate_settlement_vm(vm, va, minp, maxp)
end)
