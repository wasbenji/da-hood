--[[
  DA HOOD
  Was_Benji (Discord) + Claude Sonnet 4.6

  Anti-stomp: probe build — testing force reset approaches
]]

print("[DaHood] booting...")

local Players = game:GetService("Players")
local WS      = game:GetService("Workspace")
local lp      = Players.LocalPlayer

local KEY = { STOMP=0x45, CARRY=0x47 }
local OFF_PRIMITIVE  = 0x148
local OFF_CFRAME     = 0xC0
local OFF_HUM_VEL    = 0x18C
local OFF_WALKSPEED  = 0x1A8

-- Health offset candidates to probe
-- Standard Roblox humanoid health is around 0x100-0x120
local HEALTH_OFFSETS = {
    0x100, 0x104, 0x108, 0x10C,
    0x110, 0x114, 0x118, 0x11C,
    0x120, 0x124, 0x128, 0x12C,
    0x130, 0x140, 0x150, 0x160,
}
local HEALTH_OFFSET = nil  -- confirmed after probe

local STATE = {
    target=nil, targetName=nil,
    orbitActive=false, orbitBusy=false, orbitStart=nil,
    orbitRadius=15, orbitSpeed=0,
    stompActive=false,
    voidActive=false, voidStart=nil,
    antiStompOn=false, antiStompVoidOn=true,
    antiStompMethod="probe",  -- "loadchar" | "health" | "void"
    healthSaveOn=true, healthThresh=30,
    autoStompOn=false, carryAfterStomp=true,
    killAuraOn=false,
    speedOn=false, speedVal=300,
    fakeLagOn=false,
    kickStaffOnJoin=false,
    autoTargetOn=false,
}

local function safeCall(fn) local ok,e=pcall(fn); if not ok then print("[ERR] "..tostring(e)) end end
local function getChar() return lp.Character end
local function getHRP() local c=getChar(); return c and c:FindFirstChild("HumanoidRootPart") end

local function getTorsoPos(plr)
    if not plr or not plr.Character then return nil end
    local c=plr.Character
    local p=c:FindFirstChild("UpperTorso") or c:FindFirstChild("Torso")
           or c:FindFirstChild("LowerTorso") or c:FindFirstChild("HumanoidRootPart")
    return p and p.Position
end

local function getStatus(plr)
    if not plr or not plr.Character then return "no_char" end
    local be=plr.Character:FindFirstChild("BodyEffects"); if not be then return "no_be" end
    local ko=be:FindFirstChild("K.O"); local dead=be:FindFirstChild("Dead")
    local sd=be:FindFirstChild("SDeath")
    if not ko or not dead then return "no_vals" end
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
    if STATE.target and hasSP(STATE.target) then return true,"spawn protection" end
    if STATE.healthSaveOn and myHP()<STATE.healthThresh then
        return true,"low HP ("..math.floor(myHP())..")"
    end
    return false,nil
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
local function getPrimitive(part)
    local addr=part.Address; if not addr or addr==0 then return nil end
    local prim=memory_read("uintptr",addr+OFF_PRIMITIVE)
    return (prim and prim~=0) and prim or nil
end
local function writeUprightRot(pa)
    if not pa then return end; local b=pa+OFF_CFRAME
    memory_write("float",b+0x00,1);memory_write("float",b+0x04,0);memory_write("float",b+0x08,0)
    memory_write("float",b+0x0C,0);memory_write("float",b+0x10,1);memory_write("float",b+0x14,0)
    memory_write("float",b+0x18,0);memory_write("float",b+0x1C,0);memory_write("float",b+0x20,1)
end
local function cancelVelocity(part)
    if not part then return end
    local prim=getPrimitive(part); if not prim then return end
    memory_write("float",prim+0xF0,0);memory_write("float",prim+0xF4,0);memory_write("float",prim+0xF8,0)
end
local function resetHumVelocity()
    local c=getChar(); if not c then return end
    local h=c:FindFirstChild("Humanoid"); if not h then return end
    local addr=h.Address; if not addr then return end
    safeCall(function()
        memory_write("float",addr+OFF_HUM_VEL,  0)
        memory_write("float",addr+OFF_HUM_VEL+4,0)
        memory_write("float",addr+OFF_HUM_VEL+8,0)
    end)
end
local function setSpeedMem(speed)
    local c=getChar(); if not c then return end
    local h=c:FindFirstChild("Humanoid"); if not h then return end
    local addr=h.Address; if not addr or addr==0 then return end
    memory_write("float",addr+OFF_WALKSPEED,speed)
end

-- ================================================================
-- HEALTH OFFSET PROBE
-- Scans humanoid memory to find health value
-- Health is typically a float near 100 or the player's max health
-- ================================================================
local function probeHealthOffset()
    local c=getChar(); if not c then print("[HealthProbe] no char"); return end
    local h=c:FindFirstChild("Humanoid"); if not h then return end
    local addr=h.Address
    if not addr or addr==0 then print("[HealthProbe] no address"); return end

    local currentHP=h.Health
    print(string.format("[HealthProbe] Current HP (property): %.1f",currentHP))
    print("[HealthProbe] Scanning offsets for value near "..currentHP.."...")

    for _,off in ipairs(HEALTH_OFFSETS) do
        local ok,val=pcall(function() return memory_read("float",addr+off) end)
        if ok and val then
            local diff=math.abs(val-currentHP)
            local marker=""
            if diff<5 then
                marker=" *** CANDIDATE (near HP) ***"
                if not HEALTH_OFFSET then
                    HEALTH_OFFSET=off
                    print(string.format("[HealthProbe] *** CONFIRMED offset 0x%X = %.2f ***",off,val))
                end
            end
            if val>0 and val<500 then  -- plausible health range
                print(string.format("[HealthProbe] 0x%X = %.2f%s",off,val,marker))
            end
        end
    end
    if not HEALTH_OFFSET then
        print("[HealthProbe] No match — HP may not be a plain float at these offsets")
    end
end

-- ================================================================
-- FORCE RESET — the real anti-stomp used by ALL Da Hood scripts
-- Researched approach: LoadCharacter() = instant respawn = no stomp
-- Backup: health = 0 via memory
-- Backup2: destroy character parts (ragdoll trick from Parzival X)
-- ================================================================
local function forceReset()
    -- Method 1: LoadCharacter — most reliable, instant respawn
    local ok1=pcall(function() lp:LoadCharacter() end)
    print("[AntiStomp] LoadCharacter: "..tostring(ok1))
    if ok1 then
        STATE.antiStompMethod="loadchar"
        return true
    end

    -- Method 2: Health = 0 via property
    local ok2=pcall(function()
        local h=getChar() and getChar():FindFirstChild("Humanoid")
        if h then h.Health=0 end
    end)
    print("[AntiStomp] Health=0 (property): "..tostring(ok2))
    if ok2 then STATE.antiStompMethod="health_prop"; return true end

    -- Method 3: Health = 0 via memory
    if HEALTH_OFFSET then
        local c=getChar(); local h=c and c:FindFirstChild("Humanoid")
        if h and h.Address then
            local ok3=pcall(function()
                memory_write("float",h.Address+HEALTH_OFFSET,0)
            end)
            print("[AntiStomp] Health=0 (memory 0x"..string.format("%X",HEALTH_OFFSET).."): "..tostring(ok3))
            if ok3 then STATE.antiStompMethod="health_mem"; return true end
        end
    end

    -- Method 4: Destroy character parts (forces ragdoll reset)
    -- Same technique used in Parzival X Da Hood script
    local ok4=pcall(function()
        local c=getChar(); if not c then return end
        for _,v in ipairs(c:GetChildren()) do
            if v:IsA("MeshPart") or v:IsA("Part") then
                v:Destroy()
            end
        end
    end)
    print("[AntiStomp] DestroyParts: "..tostring(ok4))
    if ok4 then STATE.antiStompMethod="destroy"; return true end

    print("[AntiStomp] ALL methods failed — void only")
    STATE.antiStompMethod="void"
    return false
end

-- ================================================================
-- MOVEMENT
-- ================================================================
local function teleportTo(pos)
    local hrp=getHRP(); if not hrp then return end
    safeCall(function()
        hrp.Position=Vector3.new(pos.X,pos.Y+3,pos.Z)
        cancelVelocity(hrp)
    end)
end
local function randomVoidPos()
    return Vector3.new(math.random(-999999,999999),math.random(50000,999999),math.random(-999999,999999))
end
local function randomOrbitPoint(center,radius)
    local theta=math.random()*math.pi*2
    local phi=math.acos(2*math.random()-1)
    local r=radius*(0.7+math.random()*0.3)
    return Vector3.new(
        center.X+r*math.sin(phi)*math.cos(theta),
        center.Y+r*math.cos(phi),
        center.Z+r*math.sin(phi)*math.sin(theta)
    )
end
local function performStomp(targetPos)
    if not targetPos then return end
    local hrp=getHRP(); if not hrp then return end
    safeCall(function()
        hrp.Position=Vector3.new(targetPos.X,targetPos.Y+2.5,targetPos.Z)
        local prim=getPrimitive(hrp)
        if prim then writeUprightRot(prim); cancelVelocity(hrp) end
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
    if ret and saved then task.wait(0.25); teleportTo(saved); notify("returned","void",4) end
end
local function startVoid(autoMode)
    if STATE.voidActive then return end
    if not autoMode then
        local hrp=getHRP(); if hrp then STATE.voidStart=hrp.Position end
    end
    STATE.voidActive=true; notify("void active","void",4)
    task.spawn(function()
        while STATE.voidActive do
            local hrp=getHRP()
            if hrp then safeCall(function() hrp.Position=randomVoidPos() end) end
            task.wait(0.01)
            if autoMode and not shouldVoid() and iAmAlive() then
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
    if ret and saved then task.wait(0.25); teleportTo(saved); notify("returned to start","orbit",4) end
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
            local sv,svReason=shouldVoid()
            if sv and not STATE.voidActive then
                STATE.orbitActive=false; STATE.orbitBusy=false
                notify(svReason or "auto void","void",4)
                task.spawn(function() startVoid(true) end); break
            end
            if not STATE.voidActive then
                local status=getStatus(STATE.target)
                local targetPos=getTorsoPos(STATE.target)
                if STATE.autoStompOn then
                    local now=tick()
                    if status=="ko" and targetPos and now>=stompCD then
                        if not didKOVoid then
                            didKOVoid=true
                            local hrpL=getHRP()
                            if hrpL then
                                local t0=tick()
                                while tick()-t0<0.25 do
                                    safeCall(function() hrpL.Position=randomVoidPos() end)
                                    task.wait(0.01)
                                end
                            end
                        end
                        performStomp(targetPos); stompCD=tick()+0.3; STATE.stompActive=true
                    elseif status=="dead" then
                        STATE.stompActive=false; didKOVoid=false
                        STATE.orbitActive=false; STATE.orbitBusy=false
                        notify("target dead - voiding","void",4)
                        task.spawn(function() startVoid(true) end); break
                    elseif status=="alive" then
                        STATE.stompActive=false; didKOVoid=false
                    end
                end
                if status=="alive" and not STATE.stompActive and targetPos then
                    local newPos=randomOrbitPoint(targetPos,STATE.orbitRadius)
                    local hrpL=getHRP()
                    if hrpL then safeCall(function() hrpL.Position=newPos end) end
                end
            end
            task.wait(math.max(0.016, STATE.orbitSpeed>0 and STATE.orbitSpeed/100 or 0))
        end
        STATE.orbitBusy=false
    end)
end

-- ================================================================
-- ANTI-STOMP — force reset approach
-- Every working Da Hood anti-stomp uses LoadCharacter() or
-- destroying character parts for instant respawn.
-- Void alone doesn't work — stomp registers before void fires.
-- ================================================================
task.spawn(function()
    local wasKO=false
    local resetProbed=false
    while true do
        if STATE.antiStompOn then
            local ko=isKOd()
            if ko then
                if not wasKO then
                    wasKO=true
                    notify("anti-stomp triggered","defense",2)
                    print("[AntiStomp] KO detected — attempting force reset")

                    -- Probe all methods on first trigger
                    if not resetProbed then
                        resetProbed=true
                        task.spawn(function()
                            probeHealthOffset()
                        end)
                    end

                    -- Try force reset immediately
                    task.spawn(forceReset)
                end

                -- Always void as backup while KO state persists
                if STATE.antiStompVoidOn then
                    local hrp=getHRP()
                    if hrp then safeCall(function() hrp.Position=randomVoidPos() end) end
                end
                resetHumVelocity()

            else
                if wasKO then
                    wasKO=false
                    print("[AntiStomp] KO ended, method used: "..STATE.antiStompMethod)
                end
            end
        else wasKO=false end
        task.wait()
    end
end)

-- ================================================================
-- KILL AURA
-- ================================================================
local killAuraCDs={}
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
                        if tpos then
                            local dist=(tpos-myPos).Magnitude
                            local cd=killAuraCDs[p.Name] or 0
                            if dist<30 and now>=cd then
                                killAuraCDs[p.Name]=now+1.5
                                task.spawn(function() performStomp(tpos) end)
                            end
                        end
                    end
                end
            end
        else
            if next(killAuraCDs)~=nil then killAuraCDs={} end
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
        if STATE.speedOn then pcall(setSpeedMem, STATE.speedVal) end
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
                    safeCall(function()
                        hrp.Position=Vector3.new(
                            real.X+math.random(-500,500),real.Y,real.Z+math.random(-500,500))
                    end)
                    task.wait()
                    safeCall(function() hrp.Position=real end)
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
                local best,bestDist=nil,math.huge
                for _,p in ipairs(Players:GetPlayers()) do
                    if p~=lp and p.Character and getStatus(p)=="alive" then
                        local pp=getTorsoPos(p)
                        if pp then
                            local d=(pp-myPos).Magnitude
                            if d<bestDist then bestDist=d; best=p end
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
            print("[GM] "..n.." users tracked")
            for _,p in ipairs(Players:GetPlayers()) do
                local info=GM.tracked[p.Name:lower()]
                if info and not GM.notified[p.Name] then
                    GM.notified[p.Name]=true
                    notify(p.Name.." in server","rank: "..info.rank,60)
                    if STATE.kickStaffOnJoin then
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
            GM.notified[p.Name]=true; notify(p.Name.." joined","rank: "..info.rank,60)
            if STATE.kickStaffOnJoin then
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
local CAM=WS.CurrentCamera; local SW2=CAM.ViewportSize.X
local function newDraw(c,d) local o=Drawing.new(c); if d then for k,v in pairs(d) do o[k]=v end end; return o end
local hudBg=newDraw("Square",{Filled=true, Color=Color3.fromRGB(10,12,18),  Size=Vector2.new(210,96),Position=Vector2.new(SW2-220,10),Visible=true,Corner=6})
local hudBd=newDraw("Square",{Filled=false,Color=Color3.fromRGB(220,70,70), Size=Vector2.new(210,96),Position=Vector2.new(SW2-220,10),Visible=true,Corner=6,Thickness=2})
local hudTx=newDraw("Text",  {Color=Color3.fromRGB(220,220,220),Size=13,Font=Drawing.Fonts.Monospace,Outline=true,Visible=true,Position=Vector2.new(SW2-212,18)})
local function updateHUD()
    local function st(v) return v and "ON" or "off" end
    local tn=STATE.targetName or "(none)"; if #tn>13 then tn=tn:sub(1,11)..".." end
    local ts=""; if STATE.target then ts=" ["..getStatus(STATE.target).."]" end
    local antiStr=not STATE.antiStompOn and "off"
                  or (STATE.antiStompVoidOn and "["..STATE.antiStompMethod.."]" or "ON")
    hudTx.Text=string.format(
        "Da Hood\ntarget: %s%s\norbit:%s stomp:%s\nvoid:%s  aura:%s\nanti:%s  spd:%s",
        tn,ts,st(STATE.orbitActive),st(STATE.autoStompOn),
        st(STATE.voidActive),st(STATE.killAuraOn),
        antiStr,st(STATE.speedOn))
end
task.spawn(function() while true do task.wait(0.5); pcall(updateHUD) end end)

-- ================================================================
-- MATCHA UI TAB
-- ================================================================
UI.AddTab("Da Hood", function(tab)

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
        if pos then teleportTo(pos) else notify("no position","tp",3) end
    end)
    tSec:Button("Clear Target",function()
        if STATE.orbitActive then stopOrbit(true) end
        STATE.target=nil; STATE.targetName=nil; notify("cleared","target",3)
    end)

    local pSec=tab:Section("Players","Right")
    for _,p in ipairs(Players:GetPlayers()) do
        if p~=lp then
            local pName=p.Name
            pSec:Button(pName,function()
                STATE.targetName=pName; STATE.orbitStart=nil; resolveTarget()
                if STATE.target then notify("target: "..pName,"target",4)
                else notify(pName.." left","target",3) end
            end)
        end
    end

    local oSec=tab:Section("Orbit","Left")
    oSec:Toggle("t_orbit","Orbit",false,function(v)
        if v then
            if not STATE.targetName then notify("select target first","orbit",4); UI.SetValue("t_orbit",false); return end
            resolveTarget()
            if not STATE.target then notify("not in server","orbit",4); UI.SetValue("t_orbit",false); return end
            startOrbit()
        else stopOrbit(true) end
    end)
    oSec:Toggle("t_stomp","Auto Stomp",false,function(v)
        STATE.autoStompOn=v; notify(v and "stomp ON" or "off","stomp",3)
    end)
    oSec:Toggle("t_carry","Carry After Stomp",true,function(v) STATE.carryAfterStomp=v end)
    oSec:Toggle("t_aura","Kill Aura (KO / 30m)",false,function(v)
        STATE.killAuraOn=v; notify(v and "kill aura ON" or "off","aura",3)
    end)

    local vSec=tab:Section("Void","Right")
    vSec:Toggle("t_void","Manual Void",false,function(v)
        if v then startVoid(false) else stopVoid(true) end
    end)
    vSec:Toggle("t_hsave","Health Save Void",true,function(v) STATE.healthSaveOn=v end)
    vSec:Button("Return from Void",function() stopVoid(true); UI.SetValue("t_void",false) end)
    vSec:Button("Return to Orbit Start",function()
        if STATE.orbitStart then teleportTo(STATE.orbitStart); notify("returned","pos",3)
        else notify("no start saved","pos",3) end
    end)

    local dSec=tab:Section("Defense","Left")
    dSec:Toggle("t_anti","Anti Stomp",false,function(v)
        STATE.antiStompOn=v; notify(v and "anti-stomp ON" or "off","defense",3)
    end)
    dSec:Toggle("t_antivoid","  + Void on KO backup",true,function(v)
        STATE.antiStompVoidOn=v
    end)
    dSec:Button("Run Anti-Stomp Probe",function()
        task.spawn(function()
            probeHealthOffset()
            notify("probe done — check console","probe",4)
        end)
    end)
    dSec:Toggle("t_fakelag","Fake Lag",false,function(v)
        STATE.fakeLagOn=v; notify(v and "fake lag ON" or "off","lag",3)
    end)

    local mSec=tab:Section("Misc","Right")
    mSec:Toggle("t_speed","Speed Hack (300)",false,function(v)
        STATE.speedOn=v; notify(v and "speed ON" or "off","move",3)
    end)
    mSec:Toggle("t_kick","Kick Staff on Join",false,function(v) STATE.kickStaffOnJoin=v end)
    mSec:Text("Stars / Verified / Staff groups")

    local tpSec=tab:Section("Teleports","Left")
    tpSec:Button("Police Station",function()
        teleportTo(Vector3.new(-267,23,-73)); notify("TP: Police Station","tp",3)
    end)
    tpSec:Button("Hood Kicks",function()
        teleportTo(Vector3.new(-225,19,-410)); notify("TP: Hood Kicks","tp",3)
    end)
    tpSec:Button("Sewers (RPG)",function()
        teleportTo(Vector3.new(-264,-1,-318)); notify("TP: Sewers","tp",3)
    end)
    tpSec:Button("Jail",function()
        teleportTo(Vector3.new(-294,20,-68)); notify("TP: Jail","tp",3)
    end)
    tpSec:Button("Turf A",function()
        teleportTo(Vector3.new(-928,58,-221)); notify("TP: Turf A","tp",3)
    end)
    tpSec:Button("Turf B",function()
        teleportTo(Vector3.new(46,63,-875)); notify("TP: Turf B","tp",3)
    end)
    tpSec:Button("Print My Position",function()
        local hrp=getHRP(); if not hrp then return end
        local p=hrp.Position
        local s=string.format("%.0f, %.0f, %.0f",p.X,p.Y,p.Z)
        print("[Pos] "..s); notify(s,"pos",5)
    end)

    local cSec=tab:Section("Controls","Right")
    cSec:Text("X = orbit   V = stomp   C = void")
    cSec:Button("Stop All",function()
        stopOrbit(true); stopVoid(false)
        STATE.autoStompOn=false; STATE.killAuraOn=false
        STATE.voidActive=false; STATE.fakeLagOn=false; STATE.speedOn=false
        UI.SetValue("t_orbit",false); UI.SetValue("t_void",false)
        UI.SetValue("t_stomp",false); UI.SetValue("t_aura",false)
        UI.SetValue("t_fakelag",false); UI.SetValue("t_speed",false)
        notify("all stopped","stop",3)
    end)

end)

-- ================================================================
-- KEYBINDS
-- ================================================================
local KB={orbit={key=88,was=false,cd=0},stomp={key=86,was=false,cd=0},void={key=67,was=false,cd=0}}
task.spawn(function()
    while true do
        local now=os.clock()
        local function chk(b,fn)
            local d=iskeypressed(b.key)
            if d and not b.was and now>=b.cd then b.cd=now+0.3; fn() end
            b.was=d
        end
        chk(KB.orbit,function()
            if STATE.orbitActive then stopOrbit(true); UI.SetValue("t_orbit",false)
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
            if STATE.voidActive then stopVoid(true); UI.SetValue("t_void",false)
            else startVoid(false); UI.SetValue("t_void",true) end
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
    -- Probe health offset at boot while character exists
    task.wait(2); task.spawn(probeHealthOffset)
end)

print("[DaHood] ready — X=orbit  V=stomp  C=void")
print("[DaHood] Anti-stomp: will probe LoadCharacter/health/DestroyParts on first KO")
notify("Da Hood","Was_Benji + Claude",5)
