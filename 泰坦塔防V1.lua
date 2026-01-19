-- Titan TD Macro · v4.8 · MoonVeil Compatible FULL
-- Core logic unchanged | Only obfuscation-safe refactor
-- Each tower uses its own UpgradeRem (NO Tower1 issue)

--------------------------------------------------
-- String Pool (MoonVeil Safe)
--------------------------------------------------
local __D=function(t,o)
    local r={}
    for i=1,#t do r[i]=string.char(t[i]-o) end
    return table.concat(r)
end
local __K=11
local __S={
    {93,123,120,123,122,119,116,127,110},        -- UpgradeRem
    {91,119,106,124,110,98,116,124,110,123},     -- PlaceTower
    {96,123,116,110,123,116,98,110,124},         -- Vector3
    {87,110,127,110},                            -- Wave
    {85,124,115,116,98,110},                     -- Towers
}
local function S(i) return __D(__S[i],__K) end

--------------------------------------------------
-- Services
--------------------------------------------------
local G=game
local RS=G:GetService("ReplicatedStorage")
local Players=G:GetService("Players")
local Http=G:GetService("HttpService")
local WS=G:GetService("Workspace")
local UIS=G:GetService("UserInputService")

local LP=Players.LocalPlayer
local PG=LP:WaitForChild("PlayerGui")

--------------------------------------------------
-- UI
--------------------------------------------------
local Rayfield=loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local function notify(t,c)
    Rayfield:Notify({Title=t,Content=c,Duration=3})
end

--------------------------------------------------
-- State (index-based, MoonVeil safe)
--------------------------------------------------
local ST={
    false,  -- [1] recording
    false,  -- [2] playing
    {},     -- [3] macro
    0,      -- [4] start
    1,      -- [5] towerIndex
    {},     -- [6] towerById
    {},     -- [7] idByTower
    {},     -- [8] pendingQueue
    {},     -- [9] upgradeCount
    nil,    -- [10] selectedTowerId
}

local strictMode=true
local seenModels={}

--------------------------------------------------
-- Encode / Decode
--------------------------------------------------
local function enc(v)
    if typeof(v)==S(3) then
        return {__t=S(3),x=v.X,y=v.Y,z=v.Z}
    end
    return v
end
local function dec(v)
    if type(v)=="table" and v.__t==S(3) then
        return Vector3.new(v.x,v.y,v.z)
    end
    return v
end
local function encArgs(a)
    local t={}
    for i,v in ipairs(a) do t[i]=enc(v) end
    return t
end
local function decArgs(a)
    local t={}
    for i,v in ipairs(a) do t[i]=dec(v) end
    return t
end

--------------------------------------------------
-- Helpers
--------------------------------------------------
local function waitWave()
    while true do
        task.wait(0.25)
        for _,v in ipairs(PG:GetDescendants()) do
            if v:IsA("TextLabel") and v.Text and v.Text:lower():find(S(4):lower()) then
                return
            end
        end
    end
end

local function isTower(m)
    if not m or not m:IsA("Model") then return false end
    if not m:FindFirstChildWhichIsA("BasePart",true) then return false end
    if m:FindFirstChild("Level",true) then return true end
    local p=m.Parent
    if p and p.Name==S(5) then return true end
    return false
end

local function findUpgradeRemote(m)
    if not m then return end
    for _,v in ipairs(m:GetDescendants()) do
        if (v:IsA("RemoteEvent") or v:IsA("RemoteFunction"))
        and string.find(v.Name:lower(),S(1):lower()) then
            return v
        end
    end
end

--------------------------------------------------
-- Tower Bind
--------------------------------------------------
WS.DescendantAdded:Connect(function(o)
    if not (ST[1] or ST[2]) then return end
    if #ST[8]==0 then return end
    task.wait(0.15)

    local m=o:IsA("Model") and o or o:FindFirstAncestorWhichIsA("Model")
    if not isTower(m) or seenModels[m] then return end

    local id=table.remove(ST[8],1)
    ST[6][id]=m
    ST[7][m]=id
    seenModels[m]=true

    print("[Bind] Tower",id,m.Name)
end)

--------------------------------------------------
-- Input Select
--------------------------------------------------
local function rayPick(pos)
    local cam=WS.CurrentCamera
    local ray=cam:ScreenPointToRay(pos.X,pos.Y)
    local res=WS:Raycast(ray.Origin,ray.Direction*5000)
    return res and res.Instance
end

local function findTower(inst)
    local d=0
    while inst and d<20 do
        if ST[7][inst] then return inst end
        inst=inst.Parent
        d=d+1
    end
end

UIS.InputBegan:Connect(function(i,gp)
    if gp or not ST[1] then return end
    local pos
    if i.UserInputType==Enum.UserInputType.Touch then
        pos=i.Position
    elseif i.UserInputType==Enum.UserInputType.MouseButton1 then
        pos=UIS:GetMouseLocation()
    else return end

    local hit=rayPick(pos)
    if not hit then return end
    local m=findTower(hit)
    if not m then return end

    ST[10]=ST[7][m]
    notify("Selected","Tower ID "..ST[10])
end)

--------------------------------------------------
-- Record
--------------------------------------------------
local function recordPlace(m,remote,args)
    if not ST[1] or m~="FireServer" then return end
    if remote.Name~=S(2) then return end

    local id=tostring(ST[5])
    ST[5]+=1
    ST[9][id]=0

    table.insert(ST[3],{
        tick()-ST[4],
        S(2),
        encArgs(args),
        id,false,{targetName=id}
    })
    table.insert(ST[8],id)
    print("[Place]",id)
end

local function recordUpgrade(m,remote)
    if not ST[1] or m~="FireServer" then return end
    if not string.find(remote.Name:lower(),S(1):lower()) then return end
    local id=ST[10]
    if not id then
        notify("Error","Select tower first")
        return
    end
    ST[9][id]=(ST[9][id] or 0)+1
    table.insert(ST[3],{
        tick()-ST[4],
        S(1),
        {},
        tostring(id),
        false,{u=ST[9][id],s=1}
    })
    print("[Upgrade]",id,ST[9][id])
end

--------------------------------------------------
-- Hook
--------------------------------------------------
local __old
__old=hookmetamethod(game,"__namecall",function(self,...)
    local m=getnamecallmethod()
    if typeof(self)=="Instance" then
        local a={...}
        pcall(function()
            recordPlace(m,self,a)
            recordUpgrade(m,self)
        end)
    end
    return __old(self,...)
end)

--------------------------------------------------
-- Playback
--------------------------------------------------
local FILE="td_macro.json"

local function quickUpgrade(id)
    local m=ST[6][tostring(id)]
    if not m then return end
    local r=findUpgradeRemote(m)
    if r then pcall(function() r:FireServer() end) end
end

local function play()
    if ST[2] then return end
    if not isfile(FILE) then return end

    ST[2]=true
    ST[6]={};ST[7]={};ST[8]={};seenModels={}

    waitWave()
    local data=Http:JSONDecode(readfile(FILE))
    local PlaceRem=RS:FindFirstChild(S(2),true)

    local last=0
    for _,it in ipairs(data) do
        local t,r,a,id=it[1],it[2],it[3],it[4]
        task.wait(t-last)
        last=t

        if r==S(2) then
            table.insert(ST[8],id)
            PlaceRem:FireServer(unpack(decArgs(a)))
        elseif r==S(1) then
            quickUpgrade(id)
        end
    end

    ST[2]=false
    notify("Done","Playback finished")
end

--------------------------------------------------
-- UI
--------------------------------------------------
local W=Rayfield:CreateWindow({Name="泰坦塔防",KeySystem=false})
local T=W:CreateTab("Main",4483362458)

T:CreateButton({
    Name="录制",
    Callback=function()
        waitWave()
        ST[1]=true
        ST[3]={}
        ST[4]=tick()
        ST[5]=1
        ST[6]={};ST[7]={};ST[8]={};ST[9]={}
        ST[10]=nil
        seenModels={}
        notify("录制","已开始")
    end
})

T:CreateButton({
    Name="保存",
    Callback=function()
        ST[1]=false
        writefile(FILE,Http:JSONEncode(ST[3]))
        notify("已保存","对")
    end
})

T:CreateButton({
    Name="回放",
    Callback=function()
        play()
    end
})

notify("已加载","成功")
