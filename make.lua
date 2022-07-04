--[[
LUAMAKE by rnd, 2022

build automation tool compatible with basic functionality of https://en.wikipedia.org/wiki/GNU_make
~300 lines of code. made in 4-5 days, on/off..

----------------------------------------------
USAGE:
  write instructions how to create your desired files using commands below. save instructions
  if file named 'makefile'. run 'lua make.lua' in same folder as 'makefile'.

  optional:
    set up 'loglevel' variable for more detailed printouts. default level 2 (detailed.)

TUTORIAL MAKEFILE EXAMPLE:

#this is comment
#format of rule to create out files fron input files:

out1 out2 ... outn : input1 input2 ... inputn
TAB command1
TAB command2
..
TAB commandn

#example of variables - note that variable definition begins IMMEDIATELY after =
varname =input1 input2 ... inputn
GCC =gcc.exe
#this variable can be later used in other commands using $(GCC)

#its possible to join variables like:
var1 =hello
var2 =world
var3 =$(hello) $(world)!
var4 =$(hello),$(world).
#we get: var3 = "hello world!" and var4="hello,world."
#you can use variables in commands too.

#example of function getting all source files:
sources = $(wildcard *.c)

#example of function modifying file names using existing variable, this uses lua patterns and string.gsub internally:
#this will modify file names 'filename.c' to 'filename.o'
objects =$(patsubst $(sources),%.c,%.o)

#when using several files command will be run in loop over those files.
#here $< represents input file name and $@ output file name:
$(objects) : $(sources)
	$(GCC) $< -o $@

#HOW IT WORKS:
#running make tries to do default target (which is first target in makefile)
#it expands all dependencies of target and  puts them into stack. it keeps expanding until it can execute target.
#it checks if some output has newer file change timestamp than input OR output nonexistent. in that case it rebuilds that target
#when using loop (with $< and $@) it will check timestamps individually and only create files that need to be created.
--]]

--HELPER FUNCTIONS

-- debug printout, you can set loglevel thus adjusting details
local loglevel = 2; -- 1: verbose, 2:detailed, 3: debug, 4: debug with makefile processing
local dprint = function(text)
  print(text)
end


--return last modified time for file in seconds
-- this runs 'console' command in windows and reads 'modified time' from its output
function get_file_time(filepath)
    local pipe = io.popen('dir /4/T:W "'..filepath..'"')
    local output = pipe:read"*a"
    pipe:close()
    local d,mo,y,h,m,p
    mo,d,y,h,m,p = output:match"\n(%d%d)/(%d%d)/(%d%d%d%d)%s%s(%d%d):(%d%d)%s(%a)"
    if not h then return -1 end -- file doesnt exist, if this was output every input would be newer!
    h=h+(p=="P" and 12 or 0)
    --dprint(d,mo,y,h,m)
    return (m+60*(h)+(d+31*mo+365*y)*24*60)*60
  end

function get_current_time()
  d,mo,y,h,m,st = os.date("%d"),os.date("%m"),os.date("%Y"),os.date("%H"),os.date("%M"),os.date("%S")
  --dprint(d,mo,y,h,m)
  return (m+60*(h)+(d+31*mo+365*y)*24*60)*60+st
end

--dprint(get_current_time())
--dprint(get_file_time("make.lua"))

--return array of filenames matching the mask
--mask is from windows console 'dir' command, pattern is optional lua pattern
function list_files(mask, pattern)
  local handle = io.popen('dir /B '.. (mask or ""));
  local result = handle:read("*a")
  local out = {}
  if not pattern then
    for fname in string.gmatch(result,"[^\n]+") do
      table.insert(out,fname)
    end
  else
    for fname in string.gmatch(result,"[^\n]+") do
      if string.find(fname, pattern) then table.insert(out,fname) end
    end
  end
  return out
end

--ls = list_files("*.lua"); for i=1,#ls do dprint(i.." " ..ls[i]) end

-- finds correct ending ) matching ( at pos, returns position
find_matching_parenthesis = function(text,pos)
  local lvl = 1 -- we are already inside (), find correct ) at same level
  local i = pos;
  while i<string.len(text) do
    local j = string.find(text,"[%(%)]",i+1)
    if not j then return end -- nothing found at correct level
    if string.sub(text,j,j) == "(" then lvl = lvl+1 else lvl=lvl-1 end
    if lvl == 0 then return j end -- found correct )
    i=j
  end
  return -- no luck!
end

TEST_find_matching_parenthesis = function()
  local text = "(START (a (b))c END) d"
  local i = 1
  local j = find_matching_parenthesis(text,i);
  dprint(string.sub(text,i,j))
end
--TEST_find_matching_parenthesis()

-- parse makefile and return targets in array


outs = {}; -- [filename] = {target_id,...} --which target produces filename?
timestamps = {}; -- [filename] = time
vars = {}; -- variable, contains filenames separated by space: [varname] = "name1 name2 ..." 
targets = {} -- targets = {{in = {list ...}, out = {list ...}}, deps = {}}

expand_string_vars = function(line) -- expands variables in string and return new string
  local patt = "%$%("
  local lpatt = 2
  if not string.find(line,patt) then return line end -- no $, just return original string line
  local stringlist = {}
  local i0=1; -- start of chunk of text to add
  local i=0; -- search position
  
  while i<string.len(line) do
    i = string.find(line,patt,i+1)
    if i then -- found $(...), could be command or variable
      local j = string.find(line, "%)",i+1)
      if not j then error("missing ) in variable syntax, line:\n " .. line) end
      table.insert(stringlist,string.sub(line,i0,i-1))
      i0=j+1
      local varname = string.sub(line,i+lpatt,j-1) -- this is: $(varname)
      local ivarname = i+lpatt; -- remember for later        

      i=string.find(varname," ") -- maybe its a command: $(cmdname args...)
      if i then -- its a command like wildcard or patsubst ...!
        local cmdname = string.sub(varname,1,i-1)
        if cmdname == "wildcard" then -- wildcard, lists files
          table.insert(stringlist,table.concat(list_files(string.sub(varname,i+1))," "))
        elseif cmdname == "patsubst" then -- $(patsubst pattern,replacement,text) 
          if string.find(varname,patt) then -- possible variable inside command - find correct closing ), fix varname and compute variables first !
            local k = find_matching_parenthesis(line,j);  -- go through line, start right after 'patsubst' and stop when you get at final correct ):
            if not k then 
                error("too many $( in : " .. line .. ", lvl " .. lvl .. " sub i k : " .. string.sub(line,i,k) ) 
            else -- fixed varname, within correct ( and ) 
              i0=k+1;j=i0  -- correct end of command
              varname = string.sub(line,ivarname,k-1)
              varname = string.sub(varname,string.find(varname," ")+1)
              end
           end
          local i1 = string.find(varname, ",",1) -- find text,pattern,replacement
          local i2 = string.find(varname,",",i1+1)
          local replacement = string.sub(varname,i2+1)
          local pattern = string.sub(varname,i1+1,i2-1)
          local text = string.sub(varname,1,i1-1);
          text = string.gsub( expand_string_vars(text), pattern, replacement);
          table.insert(stringlist, text )
        end
      elseif not vars[varname] then -- variable does not exist
        error("#variable '" .. varname .. "' not defined.")
      else -- variable exists, use its value
        table.insert(stringlist,vars[varname])
      end
      i=j
    else
      table.insert(stringlist,string.sub(line,i0))
      break
    end
  end
  return table.concat(stringlist,"")
end

TEST_expand_string_vars = function()
  vars["X"] = "hello";vars["Y"] = "hi"
  dprint(expand_string_vars("a b c$(X) $(patsubst $(X)+$(Y),l,L) '$(X)'"))
end
--TEST_expand_string_vars()


-- parse_targets:
-- read targets, inputs/outputs, commands. determine target dependencies. define and expand variables
parse_targets = function(source) 
  local tcount = 0
  local mode = 0; -- 1: parsing target commands
  local tid = 0; -- target id, used in parsing commands

  for line in string.gmatch(source,"[^\n]+") do -- get lines from source
    
    if string.sub(line,1,1)  ~= "#" then -- not a comment
      if mode == 1 then -- parsing commands
        if string.byte(line,1) == 9 then -- line starts with TAB          
          -- parse commands
          local cmds = targets[tid]["cmds"]
          table.insert(cmds, string.sub(line,2)) -- insert command
        else 
          mode = 0 -- no more commands
        end
       end
      
      if mode == 0 then
        if string.find(line,":") then --contains :, must be target definition
          local delim = string.find(line,":")
          tcount = tcount+1
          
          mode = 1; -- inside target description
          tid = tcount; -- remember target id
          targets[tcount] = {}
          local data = targets[tcount]
          data["out"] = {} -- list of output "filenames" for this target
          for word in string.gmatch(expand_string_vars(string.sub(line,1,delim-1)),"%S+") do -- extract filenames from target description
            table.insert(data["out"],word)
            if not outs[word] then outs[word] = {} end
            outs[word][tcount] = true  -- mark this target as producer of filename 'word'
          end

          data["in"] = {} -- list of input "filenames" for this target [word]
          data["cmds"] = {}; -- list of commands for this target
          for word in string.gmatch(expand_string_vars(string.sub(line,delim+1)),"%S+") do
            table.insert(data["in"],word)
          end
        elseif string.find(line,"=") then -- variable definition
          local eqpos = string.find(line,"=")
          local varname = string.match(string.sub(line,1,eqpos-1),"%S+")
          local varvalue = expand_string_vars(string.sub(line,eqpos+1))
          --dprint("expanded var " .. varname .. " to : " .. varvalue)
          vars[varname] = varvalue;
        end
      end
    
    end
  end
--[[
  1.loop all targets
  2. for each output in target remember which target it was:
    outs[output] = {[target]=true,...}  - this way we know where 'output' entry comes from
    targets[i]["deps"] = {targetid1, ...} -- list of ids of targets that target i depends on
--]]
  for i = 1,tcount do -- loop all targets and determine which targets are dependent on which targets
    local target = targets[i];
    target["deps"] = {};
    local tdeps = {}; -- temporary db for dependency ids
    local tin = target["in"]
    if loglevel>=4 then dprint("TARGET " .. i .. ", #tin " .. #tin) end
    for j = 1,#tin do -- loop input filenames for this target
      local inword = tin[j]
      if loglevel>4 then dprint("   " ..inword) end
      local indepdb = outs[inword] or {} -- db of targets that produce file 'inword'
      for depid,_ in pairs(indepdb) do
        tdeps[depid] = true
      end
    end
    
    local deps = target["deps"]
    for k,v in pairs(tdeps) do -- make list of deps for target i
      table.insert(deps,k)
    end
    
    if loglevel>=4 then dprint(" deplist target " .. i .. " : " .. table.concat(target["deps"]," ")) end
    if loglevel>=4 then dprint("   #cmds : ".. #target["cmds"]) end
    if loglevel>=4  then for k,v in pairs(deps) do dprint("   ".. k) end end

  end
end

-- executes commands
-- use timestamps[filename] to read time if existing or get it from os if not
-- compare timestamps of input and output to determine if command needs to run or not
execute_cmds = function(target)
  local cmds = target["cmds"]
  local inputs = target["in"]
  local outputs = target["out"]
  
  local patts = {"%$<","$@"} -- inputs outputs
  local iocount = math.min(#inputs,#outputs)

  
  local tin=-1; -- get timestamps
  local tout = 1/0
  for i = 1,#inputs do
    local t = timestamps[inputs[i]] or get_file_time(inputs[i]);
    timestamps[inputs[i]] = t;
    if t>tin then tin = t end -- newest input
  end

  for i = 1,#outputs do
    local t = timestamps[outputs[i]] or get_file_time(outputs[i]);
    if t<tout then tout = t end
    timestamps[outputs[i]] = t; -- oldest output
  end
  
  if loglevel>=3 then dprint(" D max_tin min_tout : " .. tin .. " " .. tout) end
  --dprint(" D #cmds to run "..#cmds)

  if not(tin>tout or (tout<0)) then -- inputs are older than outputs, no need to do anything
    if loglevel>=3 then dprint("skipping ...") end
    return false 
  end 
 
  for i = 1,#cmds do
    local cmd = cmds[i];
    local looped = false
    if string.find(cmd,"%$[<@]") then looped = true end --we will loop through sources in commands that use $< or $@
    if looped then
      for j = 1,iocount do
        local tin1 = timestamps[inputs[j]]
        local tout1 = timestamps[outputs[j]]
        if tin1>tout1 or (tout1<0) then -- check if (input is newer than output OR if output is missing) then rebuild
          if loglevel>=3 then dprint("D " ..cmd .. " inputs[j]: " .. inputs[j] .. " outputs[j]: " .. outputs[j]) end
          local newcmd;
          newcmd = string.gsub(cmd,"%$<",inputs[j])
          newcmd = string.gsub(newcmd,"%$@",outputs[j])
          if loglevel>=2 then dprint("   loop run "..j.."/"..iocount .." : " .. newcmd) end
          local ret = io.popen(newcmd); dprint(" "..tostring(ret))
          timestamps[outputs[j]] = get_current_time()
        else 
          if loglevel>=3 then dprint("skip "..outputs[j]) end
        end
      end
    else
      if loglevel>=2 then dprint("   run: ".. cmd) end
       local ret = io.popen(cmd); dprint(" ".. tostring(ret))
      for j = 1,#outputs do
        timestamps[outputs[j]] = get_current_time()
      end
    end
  end
  return true
end

actions = {}; -- list of actions to do (ids of targets)
make = function() -- run targets and expand targets as necessary
  if #actions == 0 then 
    dprint("DONE.")
    return true
  end

  local tid = actions[#actions]; -- read action from stack
  local execute = false;
  if tid<0 then -- action was marked as already expanded, just execute its commands now without expanding it
    execute = true
    tid = -tid
  end
  
  --dprint("MAKE, target "..tid)
  local target = targets[tid];
  local deplist = target["deps"]
  if #deplist==0 then execute = true end-- no dependencies, just run
  if execute then
    if loglevel>=3 then dprint(" * executing target "..tid)  end
    
    execute_cmds(target)
    actions[#actions] = nil
     -- remove action, its done
  else -- expand target
    if loglevel>=3 then dprint(" + expanding target " .. tid) end
    actions[#actions] = -actions[#actions]; -- this marks action as processed
    for i = 1, #deplist do
      actions[#actions+1] = deplist[i]
    end
  end
end

-- open and read makefile
mfile = io.open("makefile","r");source = mfile:read("*a")

-- process makefile, figure out target dependencies, inputs/outputs - which one belongs where,...
parse_targets(source)

actions = {1}; -- add 1st target on queue to be made
for i = 1, 100 do
  if make() then break end -- break if done
  if loglevel>=3 then dprint(" actions " .. table.concat(actions," ")) end
end