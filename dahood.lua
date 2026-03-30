--[[
 
  
           Da Hood // Was_Benji + Claude

  KEYBINDS:
    X  = toggle orbit
    V  = toggle auto stomp
    C  = toggle void
    
  FEATURES:
    orbit       — random spherical orbit around target
    auto stomp  — stomps target when KO'd, voids before stomp
    carry       — carries after stomp (G key)
    kill aura   — stomps any KO'd player within 30 studs
    void        — teleports to random position in sky
    health void — auto voids when HP drops below threshold
    anti stomp  — LoadCharacter on KO = instant respawn, no stomp
    speed hack  — writes 300 to WalkSpeed memory offset
    fake lag    — rapid position spam then snap back
    auto target — picks closest alive player automatically
    group mon   — watches Stars / Verified / Staff groups
]]

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local WS         = game:GetService("Workspace")
local lp         = Players.LocalPlayer

local KEY = { STOMP=0x45, CARRY=0x47 }
local OFF_PRIMITIVE = 0x148
local OFF_CFRAME    = 0xC0
local OFF_HUM_VEL   = 0x18C
local OFF_WALKSPEED = 0x1A8  -- confirmed: Da Hood base = 100

local STATE = {
    target=nil, targetName=nil,
    orbitActive=false, orbitBusy=false, orbitStart=nil,
    orbitRadius=15,
    stompActive=false,
    voidActive=false, voidStart=nil,
    antiStompOn=false,
    healthSaveOn=true, healthThresh=30,
    autoStompOn=false, carryAfterStomp=true,
    killAuraOn=false,
    speedOn=false, speedVal=300,
    fakeLagOn=false,
    kickStaffOn=false,
    autoTargetOn=false,
}

-- ================================================================
-- HELPERS
-- ================================================================
local function safe(fn) local ok,e=pcall(fn); if not ok then print("[ERR]"..tostring(e)) end end
local function getChar() return lp.Character end
local function getHRP()  local c=getChar(); return c and c:FindFirstChild("HumanoidRootPart") end

local function getTorsoPos(plr)
    if not plr or not plr.Character then return nil end
    local c=plr.Character
    local p=c:FindFirstChild("UpperTorso") or c:FindFirstChild("Torso")
           or c:FindFirstChild("LowerTorso") or c:FindFirstChild("HumanoidRootPart")
    return p and p.Position
end

local function getStatus(plr)
    if not plr or not plr.Character then return "none" end
    local be=plr.Character:FindFirstChild("BodyEffects"); if not be then return "none" end
    local ko=be:FindFirstChild("K.O"); local dead=be:FindFirstChild("Dead")
    local sd=be:FindFirstChild("SDeath")
    if not ko or not dead then return "none" end
    if dead.Value or (sd and sd.Value) then return "dead" end
    if ko.Value then return "ko" end
    return "alive"
end

local function hasSP(plr)
    return plr and plr.Character and plr.Character:FindFirstChildOfClass("ForceField")~=nil
end
local function myHP()
    local c=getChar(); if not c then return 100 end
    local h=c:FindFirstChild("Humanoid"); return h and h.Health or 100
end
local function iAmAlive()
    local c=getChar(); if not c then return false end
    local h=c:FindFirstChild("Humanoid"); if not h then return false end
    return h.Health>0
end
local function isKOd()
    local c=getChar(); if not c then return false end
    local be=c:FindFirstChild("BodyEffects"); if not be then return false end
    local ko=be:FindFirstChild("K.O")
    return ko and ko.Value==true
end
local function shouldVoid()
    if STATE.target and hasSP(STATE.target) then return true end
    if STATE.healthSaveOn and myHP()<STATE.healthThresh then return true end
    return false
end
local function resolveTarget()
    if not STATE.targetName then return false end
    for _,p in ipairs(Players:GetPlayers()) do
        if p.Name==STATE.targetName then
            if STATE.target~=p then STATE.target=p end
            return true
        end
    end
    return false
end

-- ================================================================
-- MEMORY
-- ================================================================
local function getPrim(part)
    local a=part.Address; if not a or a==0 then return nil end
    local p=memory_read("uintptr",a+OFF_PRIMITIVE)
    return (p and p~=0) and p or nil
end
local function setUpright(pa)
    if not pa then return end; local b=pa+OFF_CFRAME
    memory_write("float",b+0x00,1);memory_write("float",b+0x04,0);memory_write("float",b+0x08,0)
    memory_write("float",b+0x0C,0);memory_write("float",b+0x10,1);memory_write("float",b+0x14,0)
    memory_write("float",b+0x18,0);memory_write("float",b+0x1C,0);memory_write("float",b+0x20,1)
end
local function zeroVel(part)
    if not part then return end
    local p=getPrim(part); if not p then return end
    memory_write("float",p+0xF0,0);memory_write("float",p+0xF4,0);memory_write("float",p+0xF8,0)
end
local function zeroHumVel()
    local c=getChar(); if not c then return end
    local h=c:FindFirstChild("Humanoid"); if not h or not h.Address then return end
    safe(function()
        memory_write("float",h.Address+OFF_HUM_VEL,  0)
        memory_write("float",h.Address+OFF_HUM_VEL+4,0)
        memory_write("float",h.Address+OFF_HUM_VEL+8,0)
    end)
end
local function writeSpeed(s)
    local c=getChar(); if not c then return end
    local h=c:FindFirstChild("Humanoid"); if not h or not h.Address then return end
    memory_write("float",h.Address+OFF_WALKSPEED,s)
end

-- ================================================================
-- MOVEMENT
-- ================================================================
local function tp(pos)
    local hrp=getHRP(); if not hrp then return end
    safe(function()
        hrp.Position=Vector3.new(pos.X,pos.Y+3,pos.Z)
        zeroVel(hrp)
    end)
end
local function voidPos()
    return Vector3.new(math.random(-999999,999999),math.random(50000,999999),math.random(-999999,999999))
end
local function orbitPoint(center,r)
    local t=math.random()*math.pi*2
    local phi=math.acos(2*math.random()-1)
    local rad=r*(0.7+math.random()*0.3)
    return Vector3.new(
        center.X+rad*math.sin(phi)*math.cos(t),
        center.Y+rad*math.cos(phi),
        center.Z+rad*math.sin(phi)*math.sin(t)
    )
end
local function stomp(tpos)
    if not tpos then return end
    local hrp=getHRP(); if not hrp then return end
    safe(function()
        hrp.Position=Vector3.new(tpos.X,tpos.Y+2.5,tpos.Z)
        local p=getPrim(hrp); if p then setUpright(p); zeroVel(hrp) end
    end)
    task.wait(0.05)
    keypress(KEY.STOMP); task.wait(0.05); keyrelease(KEY.STOMP)
    if STATE.carryAfterStomp then
        task.wait(0.05); keypress(KEY.CARRY); task.wait(0.05); keyrelease(KEY.CARRY)
    end
end

-- ================================================================
-- VOID
-- ================================================================
local function stopVoid(ret)
    local saved=STATE.voidStart
    STATE.voidActive=false; STATE.voidStart=nil
    if ret and saved then task.wait(0.2); tp(saved); notify("returned","void",4) end
end
local function startVoid(auto)
    if STATE.voidActive then return end
    if not auto then local hrp=getHRP(); if hrp then STATE.voidStart=hrp.Position end end
    STATE.voidActive=true; notify("void active","void",4)
    task.spawn(function()
        while STATE.voidActive do
            local hrp=getHRP()
            if hrp then safe(function() hrp.Position=voidPos() end) end
            task.wait(0.01)
            if auto and not shouldVoid() and iAmAlive() then
                STATE.voidActive=false; notify("void cleared","void",4)
            end
        end
    end)
end

-- ================================================================
-- ORBIT
-- ================================================================
local function stopOrbit(ret)
    local saved=STATE.orbitStart
    STATE.orbitActive=false; STATE.orbitBusy=false; STATE.orbitStart=nil
    if ret and saved then task.wait(0.2); tp(saved); notify("returned","orbit",4) end
end
local function startOrbit()
    if STATE.orbitBusy then return end
    if not STATE.target then notify("no target","orbit",4); return end
    local hrp=getHRP()
    if hrp and not STATE.orbitStart then STATE.orbitStart=hrp.Position end
    STATE.orbitActive=true; STATE.orbitBusy=true
    notify("orbit on","orbit",4)
    task.spawn(function()
        local stompCD=0; local didKOVoid=false
        while STATE.orbitActive do
            if not resolveTarget() then
                STATE.orbitActive=false; STATE.orbitBusy=false
                notify("target left","orbit",4); break
            end
            if shouldVoid() and not STATE.voidActive then
                STATE.orbitActive=false; STATE.orbitBusy=false
                task.spawn(function() startVoid(true) end); break
            end
            if not STATE.voidActive then
                local status=getStatus(STATE.target)
                local tpos=getTorsoPos(STATE.target)
                if STATE.autoStompOn then
                    local now=tick()
                    if status=="ko" and tpos and now>=stompCD then
                        if not didKOVoid then
                            didKOVoid=true
                            local hrpL=getHRP()
                            if hrpL then
                                local t0=tick()
                                while tick()-t0<0.25 do
                                    safe(function() hrpL.Position=voidPos() end)
                                    task.wait(0.01)
                                end
                            end
                        end
                        stomp(tpos); stompCD=tick()+0.3; STATE.stompActive=true
                    elseif status=="dead" then
                        STATE.stompActive=false; didKOVoid=false
                        STATE.orbitActive=false; STATE.orbitBusy=false
                        task.spawn(function() startVoid(true) end); break
                    elseif status=="alive" then
                        STATE.stompActive=false; didKOVoid=false
                    end
                end
                if status=="alive" and not STATE.stompActive and tpos then
                    local newPos=orbitPoint(tpos,STATE.orbitRadius)
                    local hrpL=getHRP()
                    if hrpL then safe(function() hrpL.Position=newPos end) end
                end
            end
            task.wait(0.016)
        end
        STATE.orbitBusy=false
    end)
end

-- ================================================================
-- ANTI-STOMP
-- bind to RunService.Heartbeat so the
-- check runs every single rendered frame (~60x/sec), not on a
-- task.wait() scheduler. The instant KO is true, call
-- lp:LoadCharacter() which destroys the server-side ragdoll
-- immediately — nobody can stomp what isn't there.
-- task.wait()-based loops miss the window. Heartbeat doesn't.
-- ================================================================
local antiStompConn = nil

local function startAntiStomp()
    if antiStompConn then return end
    local wasKO = false
    antiStompConn = RunService.Heartbeat:Connect(function()
        if not STATE.antiStompOn then return end
        local ko = isKOd()
        if ko and not wasKO then
            wasKO = true
            notify("anti-stomp","defense",2)
            -- Primary: force instant server-side respawn
            local ok = pcall(function() lp:LoadCharacter() end)
            if not ok then
                -- Fallback: destroy character parts (same end result)
                safe(function()
                    local c=getChar(); if not c then return end
                    for _,v in ipairs(c:GetChildren()) do
                        if v:IsA("MeshPart") or v:IsA("Part") then v:Destroy() end
                    end
                end)
            end
        end
        if not ko then wasKO=false end
        -- Always zero velocity while KO'd (belt-and-suspenders)
        if ko then zeroHumVel() end
    end)
end

local function stopAntiStomp()
    if antiStompConn then antiStompConn:Disconnect(); antiStompConn=nil end
end

-- Start the heartbeat connection immediately — it checks STATE.antiStompOn internally
startAntiStomp()

-- ================================================================
-- KILL AURA
-- ================================================================
local auraCDs={}
task.spawn(function()
    while true do
        task.wait(0.1)
        if STATE.killAuraOn then
            local hrp=getHRP()
            if hrp then
                local myPos=hrp.Position; local now=tick()
                for _,p in ipairs(Players:GetPlayers()) do
                    if p~=lp and p.Character and getStatus(p)=="ko" then
                        local tpos=getTorsoPos(p)
                        if tpos and (tpos-myPos).Magnitude<30 then
                            local cd=auraCDs[p.Name] or 0
                            if now>=cd then
                                auraCDs[p.Name]=now+1.5
                                task.spawn(function() stomp(tpos) end)
                            end
                        end
                    end
                end
            end
        else
            if next(auraCDs)~=nil then auraCDs={} end
            task.wait(0.4)
        end
    end
end)

-- ================================================================
-- SPEED
-- ================================================================
task.spawn(function()
    while true do
        task.wait()
        if STATE.speedOn then pcall(writeSpeed,STATE.speedVal) end
    end
end)

-- ================================================================
-- FAKE LAG
-- ================================================================
task.spawn(function()
    while true do
        task.wait(0.016)
        if STATE.fakeLagOn then
            local hrp=getHRP()
            if hrp then
                local real=hrp.Position
                for i=1,3 do
                    safe(function()
                        hrp.Position=Vector3.new(real.X+math.random(-500,500),real.Y,real.Z+math.random(-500,500))
                    end)
                    task.wait()
                    safe(function() hrp.Position=real end)
                end
            end
        else task.wait(0.2) end
    end
end)

-- ================================================================
-- AUTO TARGET
-- ================================================================
task.spawn(function()
    while true do
        task.wait(1)
        if STATE.autoTargetOn then
            local hrp=getHRP()
            if hrp then
                local myPos=hrp.Position
                local best,bestD=nil,math.huge
                for _,p in ipairs(Players:GetPlayers()) do
                    if p~=lp and p.Character and getStatus(p)=="alive" then
                        local pp=getTorsoPos(p)
                        if pp then
                            local d=(pp-myPos).Magnitude
                            if d<bestD then bestD=d; best=p end
                        end
                    end
                end
                if best and best.Name~=STATE.targetName then
                    STATE.target=best; STATE.targetName=best.Name
                    notify("auto: "..best.Name,"target",3)
                end
            end
        end
    end
end)

-- ================================================================
-- GROUP MONITOR
-- ================================================================
local GM={
    GROUPS={
        {name="stars",    url="https://groups.roblox.com/v1/groups/8068202/users?limit=100"},
        {name="verified", url="https://groups.roblox.com/v1/groups/10604500/users?limit=100"},
        {name="staff",    url="https://groups.roblox.com/v1/groups/17215700/users?limit=100"},
    },
    tracked={},notified={},ready=false,loading=0,
}
local function gmFetch(group,cursor)
    local url=group.url..(cursor and ("&cursor="..cursor) or "")
    local ok,res=pcall(function() return game:HttpGet(url) end)
    if not ok then GM.loading=GM.loading-1; return end
    local ok2,data=pcall(function() return game:GetService("HttpService"):JSONDecode(res) end)
    if not ok2 or not data or not data.data then GM.loading=GM.loading-1; return end
    for _,m in ipairs(data.data) do
        GM.tracked[m.user.username:lower()]={username=m.user.username,rank=m.role.name,group=group.name}
    end
    if data.nextPageCursor and data.nextPageCursor~="" then gmFetch(group,data.nextPageCursor)
    else
        GM.loading=GM.loading-1
        if GM.loading==0 then
            GM.ready=true
            local n=0; for _ in pairs(GM.tracked) do n=n+1 end
            print("[GM] "..n.." players tracked")
            for _,p in ipairs(Players:GetPlayers()) do
                local info=GM.tracked[p.Name:lower()]
                if info and not GM.notified[p.Name] then
                    GM.notified[p.Name]=true
                    notify(p.Name.." in server","["..info.group.."] "..info.rank,60)
                    if STATE.kickStaffOn then
                        pcall(function() if p.Address then memory_write("int",p.Address+0x2C8,0) end end)
                    end
                end
            end
        end
    end
end
Players.PlayerAdded:Connect(function(p)
    if STATE.targetName and p.Name==STATE.targetName then notify("target rejoined","orbit",4) end
    if GM.ready then
        local info=GM.tracked[p.Name:lower()]
        if info and not GM.notified[p.Name] then
            GM.notified[p.Name]=true
            notify(p.Name.." joined","["..info.group.."] "..info.rank,60)
            if STATE.kickStaffOn then
                pcall(function() if p.Address then memory_write("int",p.Address+0x2C8,0) end end)
            end
        end
    end
end)
Players.PlayerRemoving:Connect(function(p)
    if STATE.targetName and p.Name==STATE.targetName then
        STATE.target=nil
        if STATE.orbitActive then stopOrbit(true); notify("target left","orbit",4) end
    end
end)

-- ================================================================
-- HUD
-- ================================================================
local CAM=WS.CurrentCamera; local SW=CAM.ViewportSize.X
local function D(c,d) local o=Drawing.new(c); if d then for k,v in pairs(d) do o[k]=v end end; return o end
local bg=D("Square",{Filled=true, Color=Color3.fromRGB(8,10,16),   Size=Vector2.new(208,96), Position=Vector2.new(SW-218,10),Visible=true,Corner=6})
local bd=D("Square",{Filled=false,Color=Color3.fromRGB(210,60,60), Size=Vector2.new(208,96), Position=Vector2.new(SW-218,10),Visible=true,Corner=6,Thickness=2})
local tx=D("Text",  {Color=Color3.fromRGB(215,215,215),Size=13,Font=Drawing.Fonts.Monospace,Outline=true,Visible=true,Position=Vector2.new(SW-210,18)})
local function updateHUD()
    local function s(v) return v and "ON" or "off" end
    local tn=STATE.targetName or "none"; if #tn>13 then tn=tn:sub(1,11)..".." end
    local ts=""; if STATE.target then ts=" ["..getStatus(STATE.target).."]" end
    tx.Text=string.format(
        "Da Hood\ntarget: %s%s\norbit:%s stomp:%s\nvoid:%s  aura:%s\nanti:%s  spd:%s",
        tn,ts,s(STATE.orbitActive),s(STATE.autoStompOn),
        s(STATE.voidActive),s(STATE.killAuraOn),
        s(STATE.antiStompOn),s(STATE.speedOn))
end
task.spawn(function() while true do task.wait(0.5); pcall(updateHUD) end end)

-- ================================================================
-- MATCHA UI
-- ================================================================
UI.AddTab("Da Hood", function(tab)

    -- TARGET
    local tSec=tab:Section("Target","Left")
    tSec:InputText("t_srch","Search player","",function(txt)
        if txt=="" then return end
        for _,p in ipairs(Players:GetPlayers()) do
            if p~=lp and p.Name:lower():find(txt:lower(),1,true) then
                STATE.target=p; STATE.targetName=p.Name; STATE.orbitStart=nil
                notify("target: "..p.Name,"target",4); UI.SetValue("t_srch",""); return
            end
        end
        notify("not found","target",3)
    end)
    tSec:Toggle("t_autotarget","Auto Target (closest)",false,function(v)
        STATE.autoTargetOn=v; notify(v and "auto target ON" or "off","target",3)
    end)
    tSec:Button("TP to Target",function()
        if not STATE.target then notify("no target","tp",3); return end
        local pos=getTorsoPos(STATE.target)
        if pos then tp(pos) else notify("no position","tp",3) end
    end)
    tSec:Button("Clear Target",function()
        if STATE.orbitActive then stopOrbit(true) end
        STATE.target=nil; STATE.targetName=nil; notify("cleared","target",3)
    end)

    -- PLAYER LIST
    local pSec=tab:Section("Players","Right")
    for _,p in ipairs(Players:GetPlayers()) do
        if p~=lp then
            local pName=p.Name
            pSec:Button(pName,function()
                STATE.targetName=pName; STATE.orbitStart=nil; resolveTarget()
                if STATE.target then notify("target: "..pName,"target",4)
                else notify(pName.." not in server","target",3) end
            end)
        end
    end

    -- ORBIT
    local oSec=tab:Section("Orbit","Left")
    oSec:Toggle("t_orbit","Orbit  [X]",false,function(v)
        if v then
            if not STATE.targetName then notify("select target first","orbit",4); UI.SetValue("t_orbit",false); return end
            resolveTarget()
            if not STATE.target then notify("not in server","orbit",4); UI.SetValue("t_orbit",false); return end
            startOrbit()
        else stopOrbit(true) end
    end)
    oSec:Toggle("t_stomp","Auto Stomp  [V]",false,function(v)
        STATE.autoStompOn=v; notify(v and "stomp ON" or "off","stomp",3)
    end)
    oSec:Toggle("t_carry","Carry After Stomp",true,function(v) STATE.carryAfterStomp=v end)
    oSec:Toggle("t_aura","Kill Aura (KO / 30m)",false,function(v)
        STATE.killAuraOn=v; notify(v and "kill aura ON" or "off","aura",3)
    end)

    -- VOID
    local vSec=tab:Section("Void","Right")
    vSec:Toggle("t_void","Manual Void  [C]",false,function(v)
        if v then startVoid(false) else stopVoid(true) end
    end)
    vSec:Toggle("t_hsave","Health Save Void",true,function(v) STATE.healthSaveOn=v end)
    vSec:Button("Return from Void",function() stopVoid(true); UI.SetValue("t_void",false) end)
    vSec:Button("Return to Orbit Start",function()
        if STATE.orbitStart then tp(STATE.orbitStart); notify("returned","pos",3)
        else notify("no start saved","pos",3) end
    end)

    -- DEFENSE
    local dSec=tab:Section("Defense","Left")
    dSec:Toggle("t_anti","Anti Stomp  (heartbeat)",false,function(v)
        STATE.antiStompOn=v
        notify(v and "anti-stomp ON" or "anti-stomp off","defense",3)
    end)
    dSec:Toggle("t_fakelag","Fake Lag",false,function(v)
        STATE.fakeLagOn=v; notify(v and "fake lag ON" or "off","lag",3)
    end)

    -- MISC
    local mSec=tab:Section("Misc","Right")
    mSec:Toggle("t_speed","Speed Hack  (300)",false,function(v)
        STATE.speedOn=v; notify(v and "speed ON" or "off","move",3)
    end)
    mSec:Toggle("t_kick","Kick Staff on Join",false,function(v) STATE.kickStaffOn=v end)

    -- TELEPORTS
    local tpSec=tab:Section("Teleports","Left")
    local TPS={
        {"Police Station", Vector3.new(-267,23,-73)},
        {"Hood Kicks",     Vector3.new(-225,19,-410)},
        {"Sewers (RPG)",   Vector3.new(-264,-1,-318)},
        {"Jail",           Vector3.new(-294,20,-68)},
        {"Turf A",         Vector3.new(-928,58,-221)},
        {"Turf B",         Vector3.new(46,63,-875)},
    }
    for _,t in ipairs(TPS) do
        local name,pos=t[1],t[2]
        tpSec:Button(name,function()
            tp(pos); notify("TP: "..name,"tp",3)
        end)
    end
    tpSec:Button("Print My Position",function()
        local hrp=getHRP(); if not hrp then return end
        local p=hrp.Position
        local s=string.format("%.0f, %.0f, %.0f",p.X,p.Y,p.Z)
        print("[Pos] "..s); notify(s,"pos",5)
    end)

    -- CONTROLS
    local cSec=tab:Section("Controls","Right")
    cSec:Text("X = orbit")
    cSec:Text("V = auto stomp")
    cSec:Text("C = void")
    cSec:Button("Stop All",function()
        stopOrbit(true); stopVoid(false)
        STATE.autoStompOn=false; STATE.killAuraOn=false
        STATE.voidActive=false; STATE.fakeLagOn=false; STATE.speedOn=false
        UI.SetValue("t_orbit",false); UI.SetValue("t_void",false)
        UI.SetValue("t_stomp",false); UI.SetValue("t_aura",false)
        UI.SetValue("t_fakelag",false); UI.SetValue("t_speed",false)
        notify("all stopped","stop",3)
    end)

    -- CREDITS
    local crSec=tab:Section("Credits","Left")
    crSec:Text("Was_Benji — concept + orbit")
   
    crSec:Text("Claude Sonnet 4.6 — code")

end)

-- ================================================================
-- KEYBINDS
-- ================================================================
local KB={
    orbit={key=88,was=false,cd=0},
    stomp={key=86,was=false,cd=0},
    void ={key=67,was=false,cd=0},
}
task.spawn(function()
    while true do
        local now=os.clock()
        local function chk(b,fn)
            local d=iskeypressed(b.key)
            if d and not b.was and now>=b.cd then b.cd=now+0.3; fn() end
            b.was=d
        end
        chk(KB.orbit,function()
            if STATE.orbitActive then
                stopOrbit(true); UI.SetValue("t_orbit",false)
            elseif STATE.targetName then
                resolveTarget()
                if STATE.target then startOrbit(); UI.SetValue("t_orbit",true)
                else notify("target not in server","orbit",3) end
            else notify("no target","orbit",3) end
        end)
        chk(KB.stomp,function()
            STATE.autoStompOn=not STATE.autoStompOn
            UI.SetValue("t_stomp",STATE.autoStompOn)
            notify(STATE.autoStompOn and "stomp ON" or "stomp off","stomp",3)
        end)
        chk(KB.void,function()
            if STATE.voidActive then
                stopVoid(true); UI.SetValue("t_void",false)
            else
                startVoid(false); UI.SetValue("t_void",true)
            end
        end)
        task.wait(0.016)
    end
end)

-- ================================================================
-- BOOT
-- ================================================================
task.spawn(function()
    task.wait(1)
    GM.loading=#GM.GROUPS
    for _,g in ipairs(GM.GROUPS) do task.spawn(function() pcall(gmFetch,g,nil) end) end
end)

print("[DaHood] ready — X=orbit  V=stomp  C=void")
notify("Da Hood","Was_Benji  + Claude",5)
