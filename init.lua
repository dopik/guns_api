local STANDARD_RELAOD_TIME = 10
local STANDARD_COOLDOWN = 0.2
local STANDARD_PELLET_NUMBER = 1
local STANDARD_DMG = 2
local STANDARD_SPREAD = 0.25
local STANDARD_BULLET_TEXTURE = "guns_api_st_bullet.png"
local STANDARD_INV_TEXTURE = "guns_api_st_invimage"
local STANDARD_WIELD_TEXTURE = "guns_api_st_wieldimage"
local STANDARD_BULLET_SOUND = "guns_api_st_bullet_sound"
local STANDARD_COOLDOWN_IMAGE = "image.png"  ------   <----
local STANDARD_BULLET_VELOCITY = 60
local STANDARD_RANGE = 50
local STANDARD_MAGAZINE = 8
local STANDARD_AMMUNITION = nil


local hex = {0,1,2,3,4,5,6,7,8,9,"a","b","c","d","e"}


local curtime = os.time()
minetest.register_globalstep(function(dtime)
	curtime = curtime + dtime
	
	local inv
	local stack, meta
	local cooldown
	local maxCooldown, maxRelaod
	for _,player in pairs(minetest.get_connected_players()) do
		inv = player:get_inventory()
		
		for i = 1, inv:get_size("main"), 1 do
			stack = inv:get_stack("main", i)
			
			local tooldef = stack:get_definition()
			
			if tooldef.guns_api_standards then
				meta = stack:get_meta()
				if not meta:get_float("guns_api:maxrelaod") then
					stack = tooldef.guns_api_standards(stack)
				end
				
				if meta:get_int("guns_api:ammunition") < 0 then -- Currently reloading
					local temp = 65535*(meta:get_float("guns_api:cooldown")-curtime)/meta:get_float("guns_api:maxreload")
					
					if temp > 0 then
						stack:set_wear(math.min(65535, math.max(0, math.floor(temp))))
					else
						meta:set_int("guns_api:ammunition", meta:get_int("guns_api:maxammunition"))
						stack:set_wear(0)
					end
				else
					local temp = (meta:get_float("guns_api:cooldown")-curtime)/meta:get_float("guns_api:maxcooldown")
					
					if temp <= 0 then
						meta:set_string("color", "0x00ff00")
					else
						local g = 255*temp
						g = hex[math.floor(g/16)] .. hex[g%16]
						meta:set_string("color", "0xff" .. g .. "00")
					end
				end
			end
		end
	end
end)

local function is_walkable(nn)
	return minetest.registered_nodes[nn].walkable
end

--[[=====================================================================================
	Redefine get_targets to allow other things then players to be hit
	or to decrease the number of things that are checked
=====================================================================================--]]

local function get_targets(user, addParams)
	local all = minetest.get_connected_players()
	local targets = {}
	local user_name = user:get_player_name()
	
	for _,target in pairs(all) do
		if not(target:is_player() and target:get_player_name() == user_name) then
			targets:insert(target)
		end
	end
	
	return targets
end

local function apply_spread(dir, spread)
	local a = math.random()*2*math.pi
	local d = math.random()*math.random()*spread

	local cos, sin = math.cos, math.sin

	local u = (dir.x ~= 1 and dir.x ~=-1) and vector.new(0, dir.z, -dir.y) or vector.new(-dir.z,0,dir.x)
	u =vector.normalize(u)

	local ux = u.x
	local uy = u.y
	local uz = u.z

	u.x = dir.x^2*ux*(1-cos(a))+cos(a)+dir.x*dir.y*uy*(1-cos(a))-dir.z*sin(a)+dir.x*dir.z*uz*(1-cos(a))+dir.y*sin(a)
	u.y = dir.x*dir.y*ux*(1-cos(a))+dir.z*sin(a)+dir.y^2*uy*(1-cos(a))+cos(a)+dir.y*dir.z*uz*(1-cos(a))-dir.x*sin(a)
	u.z = dir.x*dir.z*ux*(1-cos(a))-dir.y*sin(a)+dir.y*dir.z*uy*(1-cos(a))+dir.x*sin(a)+dir.z^2*uz*(1-cos(a))+cos(a)

	u = vector.multiply(d,u)
	dir = vector.add(dir, u)
	
	return dir
end

local function line_of_sight_lin(startpos, endpos, fineness)
	local d = vector.distance(startpos, endpos)
	local maxk = math.floor(d / fineness)
	local dir = vector.divide(vector.subtract(endpos, startpos), maxk)
	
	local pos = startpos
	local nn
	for k = 0, maxk, 1 do
		nn = minetest.get_node(pos).name
		
		if is_walkable(nn) then
			return false, pos
		end
		
		pos = vector.add(pos, dir)
	end
	
	return true, vector.distance(startpos, pos), pos
end

local function hitdetection_lin(startpos, dir, minp, maxp, range, checkb, checkd, checkp)
	local hit1, hit2
	local temp1, temp2
	
	for k,v in pairs(dir) do
		if  dir[k] ~= 0 then
			temp1 =(minp[k] - startpos[k]) / dir[k]
			temp2 = (maxp[k] - startpos[k]) / dir[k]
		elseif startpos[k] < minp[k] or startpos[k] > maxp[k] then
			return false -- Didn't hit
		end
		
		if hit1 and hit2 and (temp1 > hit2 or temp2 < hit1) then
			return false -- Didn't hit
		elseif temp1 then
			hit1 = min(temp1, temp2)
			hit2 = max(temp1, temp2)
		end
		
		temp1, temp2 = false, false
	end
	temp1, temp2= nil, nil
	
	if hit1 < 0 and hit2 < 0 then
		return false -- We can't shoot backwards
	end
	
	hit1, hit2 = hit2, nil
	
	local hitpos = vector.add(vector.multiply(hit1, dir), startpos)
	
	local d = vector.distance(startpos, hitpos)
	
	if d > range then
		return false -- Target too far away
	end
	
	if checkd then
		if checkb then
			if d <= checkd then
				return true
			else
				startpos = checkp
			end
		else
			if d >= checkd then
				return false
			end
		end
	end
	
	return startpos, hitpos  -- checkb, checkd, checkp = line_of_sight_lin(startpos, hitpos, 0.1)
end

local function shoot_lin(user, targets, dmg, pellets, spread, range, startVel, bulletTexture, bulletSound, on_hit)
	-- here we do our fancy stuff(particle & sound)
	-- and hitdetection -> line_of_sight -> damage
	
	local playerHits = {}
	
	local startpos = vector.add(user:getpos(), vector.new(0,1.625,0)) -- add eye-offset
	local dir
	local minp, maxp
	local checkb, checkd, checkp
	local searchpos, hitpos

	
	for i = 1, pellets, 1 do
		-- generate spread here
		dir = user:get_look_dir()
		dir = apply_spread(dir, spread)
		-- ============
		
		for _,target in pairs(targets) do
			-- collisionbox of the target
			minp, maxp = vetor.add(target:getpos(), vector.new(-0.3,0,-0.3)), vetor.add(target:getpos(), vector.new(0.3,1.75,0.3))
			-- ====================
			
			searchpos, hitpos = hitdetection_lin(startpos, dir, minp, maxp, range, checkb, checkd, checkp)
			if hitpos then
				checkb, checkd, checkp = line_of_sight_lin(searchpos, hitpos, 0.1)
				
				if checkb then
					local targetName = target:is_player() and target:get_player_name() or target:get_name()
					playerHits[targetName] = (playerHits[targetName] or 0) + 1
				end
			end
		end
		
		checkb, checkd, checkp = nil, nil, nil
		
		-- Particle here
		minetest.add_particle({
			pos = vector.add(startpos),
			vel = vector.multiply(dir, startVel),
			expirationtime = 60,
			collisiondetection = true,
			collision_removal = true,
			size = 1,
			texture = bulletTexture,
			glow = 14,
		})
		-- =============
	end
	
	local player
	for name,amount in pairs(playerHits) do		
		player = minetest.get_player_by_name(name)
		
		if on_hit then
			on_hit(player, amount)
		end
		
		player:set_hp(player:get_hp() - math.floor(amount*dmg))
		playerHits[name] = 0
	end
	
	-- Sound here
	minetest.sound_play(bulletSound, {
        pos = startpos,
        gain = 1.0,
        max_hear_distance = 32,
    })
	-- 
end

--[[
	range
	dmg
	invTexture
	wieldTexture
	bulletTexture
	bulletSound
	pellets
	spread
	on_use
	on_hit
	reload
	cooldown
	magazine
	ammunition
--]]

local function register_gun(name, params)
	local modname = minetest.get_current_modname()
	minetest.register_tool(modname .. ":" .. name:lower():gsub("%s","_"), {
		description = name,
		tool_capabilities = {},
		inventory_image = STANDARD_COOLDOWN_IMAGE,
		color = "0x00ff00",
		inventory_overlay = params.invtexture or modname .. "_" .. name:lower():gsub("%s","_"),
		wield_overlay =  params.wieldtexture or modname .. "_" .. name:lower():gsub("%s","_"),
		on_use = function(itemstack,user,pointed_thing)
			local meta = itemstack:get_meta()
			local cooldown = meta:get_float("guns_api:cooldown") or 0
			if curtime < cooldown then -- we are waiting
				return
			end
			
			local ammunition = meta:get_int("guns_api:ammunition") or 0
			if ammunition <= 0 then -- out of ammo
				local inv = user:get_inventory()
				local ammotype = params.ammunition or STANDARD_AMMUNITION
				
				if ammotype and not inv:remove_item("main", ItemStack(ammotype)) then
					return
				end
				
				cooldown = params.cooldown or STANDARD_COOLDOWN or 0
				meta:set_float("guns_api:cooldown", cooldown)
				meta:set_string("color", "0xff0000")
				
				return itemstack
			end
			
			if params.on_use then
				params.on_use(user, itemstack)
			end
			
			shoot_lin(user, get_targets(user), params.dmg or STANDARD_DMG, params.pellets or STANDARD_PELLET_NUMBER,
					params.spread or STANDARD_SPREAD, params.range or STANDARD_RANGE, params.vel or STANDARD_BULLET_VELOCITY,
					params.bulletTexture or STANDARD_BULLET_TEXTURE, params.bulletSound or STANDARD_BULLET_SOUND, params.on_hit)
			
			ammunition = ammunition -1
			meta:set_int("guns_api:ammunition", ammunition)
			
			cooldown = curtime + (ammunition <= 0) and (params.reload or STANDARD_RELAOD_TIME or 0) or (params.cooldown or STANDARD_COOLDOWN or 0)
			meta:set_int("guns_api:cooldown", cooldown)
			
			return itemstack
		end,
		on_place = function(itemstack, placer, pointed_thing)
			if placer:get_player_control().sneak then
				local meta = itemstack:get_meta()
				meta:set_int("guns_api:ammunition",0)
				
				local inv = placer:get_inventory()
				local ammotype = params.ammunition or STANDARD_AMMUNITION
				
				if ammotype and not inv:remove_item("main", ItemStack(ammotype)) then
					return
				end
				
				meta:set_float("guns_api:cooldown", curtime + (params.reload or STANDARD_RELAOD_TIME or 0))
				meta:set_string("color", "0xff0000")
				return itemstack
			end
		end,
		on_secondary_use = function(itemstack, user, pointed_thing)
			if user:get_player_control().sneak then
				local meta = itemstack:get_meta()
				meta:set_int("guns_api:ammunition",0)
				
				local inv = user:get_inventory()
				local ammotype = params.ammunition or STANDARD_AMMUNITION
				
				if ammotype and not inv:remove_item("main", ItemStack(ammotype)) then
					return
				end
				
				meta:set_float("guns_api:cooldown", curtime + (params.reload or STANDARD_RELAOD_TIME or 0))
				meta:set_string("color", "0xff0000")
				return itemstack
			end
		end,
		guns_api_standards = function(itemstack)
			local meta = itemstack:get_meta()
			meta:set_int("guns_api:maxammunition", params.magazine or STANDARD_MAGAZINE)
			meta:set_float("guns_api:maxcooldown", params.cooldown or STANDARD_COOLDOWN)
			meta:set_float("guns_api:maxreload", params.reload or STANDARD_RELAOD_TIME)
			return itemstack
		end,
	})
end