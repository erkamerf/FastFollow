_addon.name = 'FastFollow'
_addon.author = 'DiscipleOfEris, Safety Modification by Daneblood'
_addon.version = '1.2.3b'
_addon.commands = {'fastfollow', 'ffo'}

-- TODO: pause on ranged attacks.

require('strings')
require('tables')
require('sets')
require('coroutine')
res = require('resources')
spells = require('spell_cast_times')
items = res.items
config = require('config')
texts = require('texts')
require('logger')
require('strings')

defaults = {}
defaults.show = false
defaults.min = 0.5
defaults.display = {}
defaults.display.pos = {}
defaults.display.pos.x = 0
defaults.display.pos.y = 0
defaults.display.bg = {}
defaults.display.bg.red = 0
defaults.display.bg.green = 0
defaults.display.bg.blue = 0
defaults.display.bg.alpha = 102
defaults.display.text = {}
defaults.display.text.font = 'Consolas'
defaults.display.text.red = 255
defaults.display.text.green = 255
defaults.display.text.blue = 255
defaults.display.text.alpha = 255
defaults.display.text.size = 10

settings = config.load(defaults)
box = texts.new("", settings.display, settings)

follow_me = 0
following = false
target = nil
last_target = nil
min_dist = settings.min^2
max_dist = 50.0^2
spell_dist = 20.4^2
repeated = false
last_self = nil
last_zone = os.clock()
zone_suppress = 3
zone_min_dist = 1.0^2
zoned = false
running = false
cast_time = 0
pause_delay = 0.1
pause_dismount_delay = 0.5
pauseon = S{}
co = nil
tracking = false

track_info = T{}

windower.register_event('unload', function()
  windower.send_command('ffo stop')
  coroutine.sleep(0.25) -- Reduce crash on reload, since Windower seems to crash if IPC messages are received as it's restarting.
end)

windower.register_event('addon command', function(command, ...)
  command = command and command:lower() or nil
  args = T{...}
  
  if not command then
    log('Provide a name to follow, or "me" to make others follow you.')
    log('Stop following with "stop" on a single character, or "stopall" on all characters.')
    log('Can configure auto-pausing with pauseon|pausedelay commands.')
  elseif command == 'followme' or command == 'me' then
    self = windower.ffxi.get_mob_by_target('me')
    if not self and not repeated then
      repeated = true
      windower.send_command('@wait 1; ffo followme')
      return
    end
    
    repeated = false
    windower.send_ipc_message('follow '..self.name)
    windower.send_ipc_message('track '..(settings.show and 'on' or 'off'))
  elseif command == 'stop' then
    if following then windower.send_ipc_message('stopfollowing '..following) end
    following = false
    tracking = false
  elseif command == 'stopall' then
    follow_me = 0
    following = false
    tracking = false
    windower.send_ipc_message('stop')
  elseif command == 'follow' then
    if #args == 0 then
      return windower.add_to_chat(0, 'FastFollow: You must provide a player name to follow.')
    end
    following = args[1]:lower()
    windower.send_ipc_message('following '..following)
    windower.ffxi.follow()
  elseif command == 'pauseon' then
    if #args == 0 then
      return windower.add_to_chat(0, 'FastFollow: To change pausing behavior, provide spell|item|any to pauseon.')
    end
    
    local arg = args[1]:lower()
    if arg == 'spell' or arg == 'any' then
      if pauseon:contains('spell') then pauseon:remove('spell')
      else pauseon:add('spell') end
    end
    if arg == 'item' or arg == 'any' then
      if pauseon:contains('item') then pauseon:remove('item')
      else pauseon:add('item') end
    end
    if arg == 'dismount' or arg == 'any' then
      if pauseon:contains('dismount') then pauseon:remove('dismount')
      else pauseon:add('dismount') end
    end
    
    windower.add_to_chat(0, 'FastFollow: Pausing on Spell: '..tostring(pauseon:contains('spell'))..', Item: '..tostring(pauseon:contains('item')))
    -- TODO: Save settings.
  elseif command == 'pausedelay' then
    pause_delay = tonumber(args[1])
    windower.add_to_chat(0, 'FastFollow: Setting item/spell pause delay to '..tostring(pause_delay)..' seconds.')
  elseif command == 'info' then
    if not args[1] then
      settings.show = not settings.show
    elseif args[1] == 'on' then
      settings.show = true
    elseif args[2] == 'off' then
      settings.show = false
    end
    
    windower.send_ipc_message('track '..(settings.show and 'on' or 'off'))
    
    config.save(settings)
  elseif command == 'min' then
    local dist = tonumber(args[1])
    if not dist then return end
    
    dist = math.min(math.max(0.2, dist), 50.0)
    
    settings.min = dist
    min_dist = settings.min^2
    config.save(settings)
  elseif command and #args == 0 then
    windower.send_command('ffo follow '..command)
  end
end)

windower.register_event('ipc message', function(msgStr)
  local args = msgStr:lower():split(' ')
  local command = args:remove(1)
  
  if command == 'stop' then
    follow_me = 0
    following = false
    tracking = false
    windower.ffxi.run(false)
  elseif command == 'follow' then
    if following then windower.send_ipc_message('stopfollowing '..following) end
    following = args[1]
    target_pos = nil
    last_target_pos = nil
    windower.send_ipc_message('following '..following)
    windower.ffxi.follow()
  elseif command == 'following' then
    self = windower.ffxi.get_player()
    if not self or self.name:lower() ~= args[1] then return end
    follow_me = follow_me + 1
  elseif command == 'stopfollowing' then
    self = windower.ffxi.get_player()
    if not self or self.name:lower() ~= args[1] then return end
    follow_me = math.max(follow_me - 1, 0)
  elseif command == 'update' then
    local pos = {x=tonumber(args[3]), y=tonumber(args[4])}
    track_info[args[1]] = pos
    
    if not following or args[1] ~= following then return end
    
    zoned = false
    target = {x=pos.x, y=pos.y, zone=tonumber(args[2])}
    
    if not last_target then last_target = target end
    
     if target.zone ~= -1 and (target.x ~= last_target.x or target.y ~= last_target.y or target.zone ~= last_target.zone) then
      last_target = target
    end
  elseif command == 'zone' then
    if not following or args[1] ~= following then return end
    
    local zone_line = tonumber(args[2])
    local zone_type = tonumber(args[3])
    
    if zone_line and zone_type then zone(zone_line, zone_type, target.zone, target.x, target.y) end
  elseif command == 'track' then
    tracking = args[1] == 'on' and true or false
  end
end)

windower.register_event('prerender', function()
  updateInfo()
  
  if not follow_me and not following then return end
  
  if follow_me > 0 then
    local self = windower.ffxi.get_mob_by_target('me')
    local info = windower.ffxi.get_info()
    
    if not self or not info then return end
    
    args = T{'update', self.name , info.zone, self.x, self.y}
    windower.send_ipc_message(args:concat(' '))
  elseif following then
    local self = windower.ffxi.get_mob_by_target('me')
    local info = windower.ffxi.get_info()
    
    if not self or not info then return end
    
    if tracking then
      windower.send_ipc_message('update '..self.name..' '..info.zone..' '..self.x..' '..self.y)
    end
    
    if not target then
      if running then
        windower.ffxi.run(false)
        running = false
      end
      return
    end

    distSq = distanceSquared(target, self)
    len = math.sqrt(distSq)
    if len < 1 then len = 1 end
    
    if target.zone == info.zone and distSq > min_dist and distSq < max_dist then
      windower.ffxi.run((target.x - self.x)/len, (target.y - self.y)/len)
      running = true
    elseif target.zone == info.zone and distSq <= min_dist then
      windower.ffxi.run(false)
      running = true
    elseif running then
      windower.ffxi.run(false)
      running = false
    end
  end
end)


function updateInfo()
  box:visible(settings.show)
  
  if not settings.show then return end
  
  local self = windower.ffxi.get_mob_by_target('me')
  
  if not self then
    box:visible(false)
    return
  end
  
  lines = T{}
  for char,pos in pairs(track_info) do
    local dist = math.sqrt(distanceSquared(self, pos))
    lines:insert(string.format('%s %.2f', char, dist))
  end
  
  local maxWidth = math.max(1, table.reduce(lines, function(a, b) return math.max(a, #b) end, '1'))
  for i,line in ipairs(lines) do lines[i] = lines[i]:lpad(' ', maxWidth) end
  box:text(lines:concat('\n'))
end

function distanceSquared(A, B)
  local dx = B.x-A.x
  local dy = B.y-A.y
  return dx*dx + dy*dy
end
