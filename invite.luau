--[[
    BrainyBet - Main Bot (Complet)
    Gère : auto-accept trades, deposits, withdraws,
           overflow vers stockage, récupération depuis stockage.
]]

-- ============================
-- CONFIG
-- ============================
local BACKEND_URL        = "https://brainybet.up.railway.app"
local BOT_SECRET         = "yBPEvkAVKTshlieTAvLCLsMwDvFIXO"
local LUAPOT_KEY         = "mrr_42fc341b5f87409f891330a12d934f03"
local OVERFLOW_THRESHOLD = 15    -- mis à jour depuis /api/bot/config
local STORAGE_MAX        = 180

if not game:IsLoaded() then game.Loaded:Wait() end

-- ============================
-- SERVICES
-- ============================
local HttpService         = game:GetService("HttpService")
local Players             = game:GetService("Players")
local GuiService          = game:GetService("GuiService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser         = game:GetService("VirtualUser")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local p   = Players.LocalPlayer
local pg  = p:WaitForChild("PlayerGui")

-- Anti-AFK : empêche le kick automatique après 20min d'inactivité
p.Idled:Connect(function()
    VirtualUser:Button2Down(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
    task.wait(1)
    VirtualUser:Button2Up(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
end)

-- GIDs stables par version de jeu (confirmés par décompile TradeController)
-- Overridés par getbot.lua si le serveur envoie des GIDs différents
local GID_INVITE        = "afb005f9-6e81-4e0a-8bb0-3555938a9658"
local GID_ADD           = "6b5f15fb-5cb9-4d07-a031-bbff8e641eda"
local GID_READY         = "d73acf93-6f32-44df-b813-0f6b32c7afd9"
local GID_ACCEPT        = "918ee0f5-e98f-413f-b76e-baee47b021cb"
local GID_ACCEPT_INVITE = "57624f2b-8aa9-4974-bb7a-08f058af33ef"
local gidsReady         = false

local JOB_ID = tostring(game.JobId)

-- requestData : WaitForChild comme message.txt ligne 147
local requestData
pcall(function()
    local syncFolder = ReplicatedStorage.Packages:WaitForChild("Synchronizer")
    requestData = syncFolder:FindFirstChild("RequestData")
end)

local Animals, AnimalsShared
pcall(function()
    Animals       = require(ReplicatedStorage.Datas.Animals)
    AnimalsShared = require(ReplicatedStorage.Shared.Animals)
end)

-- ============================
-- LOOP GUARD
-- ============================
if getgenv().brainyBetLoop then
    getgenv().brainyBetLoop = false
    task.wait(0.7)
end
getgenv().brainyBetLoop = true
local function alive() return getgenv().brainyBetLoop end
local function track(conn) return conn end

-- ============================
-- UI OVERLAY
-- ============================
local GUI_NAME = "BrainyBetOverlay"
-- Supprime toute ancienne instance par nom (fiable sur tous les exécuteurs)
local function cleanOldGui(container)
    pcall(function()
        for _, gui in ipairs(container:GetChildren()) do
            if gui.Name == GUI_NAME then gui:Destroy() end
        end
    end)
end
cleanOldGui(pg)
pcall(function() cleanOldGui(game:GetService("CoreGui")) end)
if gethui then pcall(function() cleanOldGui(gethui()) end) end

-- Crée le nouveau GUI — essaie CoreGui/gethui, retombe sur PlayerGui
local sg = Instance.new("ScreenGui")
sg.Name            = GUI_NAME
sg.ResetOnSpawn    = false
sg.IgnoreGuiInset  = true
pcall(function() if syn and syn.protect_gui then syn.protect_gui(sg) end end)

local sgOk = false
if gethui then pcall(function() sg.Parent = gethui(); sgOk = true end) end
if not sgOk then pcall(function() sg.Parent = game:GetService("CoreGui"); sgOk = true end) end
if not sgOk then sg.Parent = pg end

local f = Instance.new("Frame")
f.BackgroundTransparency = 1
f.Size     = UDim2.new(0, 400, 0.8, 0)
f.Position = UDim2.new(0.5, -200, 0.1, 0)
f.Parent   = sg
local l = Instance.new("UIListLayout")
l.VerticalAlignment = Enum.VerticalAlignment.Bottom
l.Padding = UDim.new(0, 5)
l.Parent  = f

local function m(txt, color)
    pcall(function()
        if not f or not f.Parent then return end   -- sécurité si f détruit
        local t = Instance.new("TextLabel")
        t.Size                 = UDim2.new(1, 0, 0, 50)
        t.BackgroundColor3     = Color3.fromRGB(0, 0, 0)
        t.BackgroundTransparency = 0.3
        t.TextColor3           = color or Color3.fromRGB(0, 255, 0)
        t.TextScaled           = true
        t.Font                 = Enum.Font.SourceSansBold
        t.Text                 = tostring(txt)
        t.Parent               = f
        task.delay(7, function() pcall(function() t:Destroy() end) end)
    end)
end
local function mWarn(txt)  m(txt, Color3.fromRGB(255, 200, 0)) end
local function mError(txt) m(txt, Color3.fromRGB(255, 80, 80))  end


local _netFolder
local InviteEvent, AddBrainrot, ReadyEvent, AcceptEvent
local sendDeposit  -- forward declare: used in spamReadyAccept (defined later)

-- State variables forward-declared so spamReadyAccept closure can see them
local isBusy, seenKeys, alreadyClicked, withdrawMode, pendingWithdrawItems
local currentTradeUser, si, tproc, tradeOpenTime, actualTradeSuccess
local hasBrainrot, depositSent, lastWaitMsg, isRetrieving, isOverflowing, lastOfferedList
-- Persistent across resetState(): survive the GUI-close race so TradeCompleted
-- arriving late can still deposit/complete for the right user
local lastTradeCompletedAt, lastSnapUser, lastSnapItems, lastWasWithdraw, tcHookActive
local completeWithdraw  -- forward declare (defined later, used by spamReadyAccept + hook)
task.spawn(function()
    local ok, err = pcall(function()
        local netFolder = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Net")
        _netFolder = netFolder
        m("Net OK (" .. #netFolder:GetChildren() .. " remotes)")
        -- Accès direct par nom (pas de require = pas de kick)
        InviteEvent = netFolder:FindFirstChild("RF/TradeService/Invite")
        AddBrainrot = netFolder:FindFirstChild("RF/TradeService/AddBrainrot")
        ReadyEvent  = netFolder:FindFirstChild("RE/TradeService/Ready")
        AcceptEvent = netFolder:FindFirstChild("RE/TradeService/Accept")
        m("Remotes: I=" .. tostring(InviteEvent and InviteEvent.Name:sub(1,24) or "nil")
          .. " A=" .. tostring(AddBrainrot and AddBrainrot.Name:sub(1,20) or "nil")
          .. " R=" .. tostring(ReadyEvent  and ReadyEvent.Name:sub(1,20)  or "nil")
          .. " Ac=" .. tostring(AcceptEvent and AcceptEvent.Name:sub(1,20) or "nil"))
    end)
    if not ok then mError("Net: "..tostring(err)) end
end)


-- spamReadyAccept : utilise FireServer direct comme message.txt
-- Quand la boucle s'arrête et qu'on avait allReady, trade complété → deposit.
local function spamReadyAccept()
    task.spawn(function()
        if not gidsReady then mWarn("spamReadyAccept: GIDs pas prêts"); return end
        local rcOk, rc = pcall(function()
            return require(game:GetService("ReplicatedStorage").Packages.ReplicatorClient)
        end)
        if not rcOk or not rc then mWarn("ReplicatorClient KO"); return end
        local state = rc.get("Trade_" .. tostring(p.UserId))
        if not state then return end
        local wasWithdraw = withdrawMode and true or false
        -- Withdraw: wait until the item-adding loop has finished putting all items in the trade
        -- before we start firing Ready/Accept (can't be ready before items are offered)
        if wasWithdraw then
            lastWasWithdraw = true
            m("spamReadyAccept WITHDRAW — attente fin ajout items...")
            local wdDeadline = tick() + 120
            while #pendingWithdrawItems > 0 and state:TryIndex({"active","data"}) and tick() < wdDeadline do
                task.wait(0.5)
            end
            if not state:TryIndex({"active","data"}) then return end  -- trade closed before items added
            if #pendingWithdrawItems > 0 then
                mWarn("Withdraw: " .. #pendingWithdrawItems .. " items pas ajoutés (timeout 120s)")
            end
            m("spamReadyAccept WITHDRAW — items OK, Ready/Accept...")
        end
        m("spamReadyAccept lancé" .. (wasWithdraw and " [WD]" or ""))
        local hadAllReady = false
        local loopStart = tick()
        -- Snapshots refreshed each iter BEFORE any task.wait so resetState() during
        -- the sleep cannot clear them (si={} reassigns, old table ref stays valid)
        local snapUser  = currentTradeUser
        local snapItems = si
        while state:TryIndex({"active","data"}) do
            -- Refresh snapshots before sleeping (also persist for the TradeCompleted hook)
            if currentTradeUser ~= "" then snapUser = currentTradeUser; lastSnapUser = currentTradeUser end
            if type(si) == "table" and #si > 0 then snapItems = si; lastSnapItems = si end
            if withdrawMode then wasWithdraw = true; lastWasWithdraw = true end
            local data = state:TryIndex({"active","data"})
            if not data then break end
            if tick() - loopStart > 180 then m("spamReadyAccept: timeout 3min"); break end
            -- Pattern exact message(1).txt : iterate data.players directement (pas pairs)
            -- Le ReplicatorClient a un __iter custom, pairs() rate les entrées
            local allReady = true
            pcall(function()
                for _, pl in data.players do
                    if pl and not pl.ready then allReady = false; return end
                end
            end)
            if not hadAllReady and allReady then
                -- Fallback pairs() si l'iter custom a retourné allReady vide (0 joueurs)
                local count = 0
                pcall(function()
                    for _ in pairs(data.players) do count = count + 1 end
                end)
                if count == 0 then allReady = false end
            end
            if allReady then
                hadAllReady = true
                m("AllReady ✓ → Accept Remote")
                pcall(function() AcceptEvent:FireServer(GID_ACCEPT) end)
                task.wait(0.1)
            else
                m("→ Ready Remote")
                pcall(function() ReadyEvent:FireServer(GID_READY) end)
                task.wait(1)
            end
        end
        m("Trade terminé (spamReadyAccept, hadAllReady=" .. tostring(hadAllReady) .. ")")
        if not isOverflowing and not isRetrieving and hadAllReady then
            tproc = true
            -- Save immediately — dedup guards in sendDeposit/completeWithdraw prevent double-save
            -- if the TradeCompleted hook already fired first.
            if wasWithdraw then
                completeWithdraw(snapUser)
            elseif snapUser ~= "" then
                m("Save to DB → " .. snapUser)
                task.spawn(function() sendDeposit(snapItems, snapUser) end)
            else
                mWarn("spamReadyAccept: hadAllReady mais snapUser vide!")
            end
        end
    end)
end

-- tryAddBrainrot : InvokeServer avec propriétés slot+animal réelles (pattern message.txt)
local function tryAddBrainrot(entry)
    while true do
        local ok, success, result = pcall(function()
            return AddBrainrot:InvokeServer(GID_ADD, entry.index, entry.animal)
        end)
        if not ok then return false end
        if success then return true end
        if type(result) == "string" then
            if result:lower():find("please wait") then
                task.wait(0.5)
            elseif result:lower():find("space") or result:lower():find("enough") then
                return "nospace"
            else
                return false
            end
        else
            return false
        end
    end
end

-- ============================
-- STATE
-- ============================
isBusy             = false
seenKeys           = {}
alreadyClicked     = {}
withdrawMode       = false
pendingWithdrawItems = {}
currentTradeUser   = ""
si                 = {}
tproc              = false
tradeOpenTime      = 0
actualTradeSuccess = false
hasBrainrot        = false
depositSent        = false
lastWaitMsg        = 0
isRetrieving        = false
isOverflowing       = false
lastOfferedList     = {}
lastTradeCompletedAt = 0
lastSnapUser        = ""
lastSnapItems       = {}
lastWasWithdraw     = false
tcHookActive        = false

-- ============================
-- HELPERS HTTP
-- ============================
local function reqHttp(method, url, body, extraHeaders)
    local req = request or http_request or (syn and syn.request) or (fluxus and fluxus.request)
    if not req then return nil end
    local headers = {
        ["Content-Type"]  = "application/json",
        ["x-bot-secret"]  = BOT_SECRET,
        ["x-bot-name"]    = p.Name
    }
    if type(extraHeaders) == "table" then
        for k, v in pairs(extraHeaders) do headers[k] = v end
    end
    local ok, res = pcall(function()
        return req({
            Url    = url,
            Method = method,
            Headers = headers,
            Body   = body and HttpService:JSONEncode(body) or nil
        })
    end)
    if not ok or not res then return nil end
    -- Normalise Success selon l'executeur (Success ou StatusCode)
    if res.Success == nil then
        res.Success = (res.StatusCode == 200 or res.StatusCode == 201)
    end
    return res
end

-- ============================
-- CHARGEMENT BLOQUANT DES GIDs
-- Le bot NE FAIT RIEN tant que getbot.lua n'a pas envoyé les GIDs au serveur
-- ============================
task.spawn(function()
    task.wait(0.5)
    while alive() do
        local ok, res = pcall(function()
            return reqHttp("GET", BACKEND_URL .. "/api/bot/config?jobId=" .. JOB_ID)
        end)
        if ok and res and res.Success then
            local parsed
            pcall(function() parsed = HttpService:JSONDecode(res.Body) end)
            local cfg = parsed and parsed.config
            local g   = cfg and cfg.gids
            local h   = cfg and cfg.hashes
            -- Stocke les hashes dès qu'ils arrivent (même sans GIDs)
            if type(h) == "table" then
                for k, v in pairs(h) do _hashes[k] = v end
            end
            -- Override GIDs si getbot en envoie (sinon on garde les fallbacks hardcodés)
            if type(g) == "table" then
                if g.Invite      then GID_INVITE        = g.Invite      end
                if g.Add         then GID_ADD           = g.Add         end
                if g.Ready       then GID_READY         = g.Ready       end
                if g.Accept      then GID_ACCEPT        = g.Accept      end
                if g.AcceptInvite then GID_ACCEPT_INVITE = g.AcceptInvite end
            end
            if cfg and cfg.overflowThreshold then OVERFLOW_THRESHOLD = cfg.overflowThreshold end
            if cfg and cfg.storageMax        then STORAGE_MAX        = cfg.storageMax        end

            if _netFolder then
                if not (InviteEvent and AddBrainrot and ReadyEvent and AcceptEvent) then
                    mWarn("Remotes manquants: I="..tostring(InviteEvent~=nil).." A="..tostring(AddBrainrot~=nil).." R="..tostring(ReadyEvent~=nil).." Ac="..tostring(AcceptEvent~=nil))
                else
                    if not gidsReady then m("Remotes OK ✓") end
                end
            end
            if not gidsReady then
                gidsReady = true
                m("Bot actif! GIDs prêts (" .. JOB_ID:sub(1,8) .. ")")
            end
        end
        if not gidsReady then
            mWarn("Attente getbot (" .. JOB_ID:sub(1,8) .. ")…")
        end
        task.wait(gidsReady and 30 or 5)
    end
end)

-- ============================
-- HELPERS UI / CLICKS
-- ============================
local function clickBtn(btn)
    task.wait(math.random(80, 200) / 1000)
    pcall(function()
        if btn:IsA("GuiButton") then
            -- Activate fires MouseButton1Click/Activated cleanly without VirtualInputManager
            btn:Activate()
        else
            local absPos  = btn.AbsolutePosition
            local absSize = btn.AbsoluteSize
            local inset   = GuiService:GetGuiInset()
            local tx = absPos.X + absSize.X / 2 + inset.X
            local ty = absPos.Y + absSize.Y / 2 + inset.Y
            VirtualInputManager:SendMouseButtonEvent(tx, ty, 0, true,  game, 1)
            task.wait(math.random(50, 130) / 1000)
            VirtualInputManager:SendMouseButtonEvent(tx, ty, 0, false, game, 1)
        end
    end)
end

-- Cooldown réel du serveur (comme bot.lua) : on ne clique Ready/Accept
-- QUE quand ce cooldown est <= 0, sinon le serveur rejette = kick
local function getTradeCooldown()
    local rcOk, ReplicatorClient = pcall(function()
        return require(game:GetService("ReplicatedStorage").Packages.ReplicatorClient)
    end)
    if rcOk and ReplicatorClient then
        local tId   = "Trade_" .. tostring(p.UserId)
        local state = ReplicatorClient.get(tId)
        if state then
            local lastChange = state:TryIndex({"active","data","lastChange"})
            if type(lastChange) == "number" then
                return (lastChange + 5.1) - workspace:GetServerTimeNow()
            end
        end
    end
    return 0
end

-- Clique le ReadyButton de façon humaine : attend le cooldown serveur, puis 1 seul clic.
-- Retourne true si cliqué, false si bouton introuvable.
local function humanClickRb(tradeGui)
    local inner = tradeGui:FindFirstChild("TradeLiveTrade")
    local rb = inner and inner:FindFirstChild("Other") and inner.Other:FindFirstChild("ReadyButton")
    if not rb or not rb.Visible then return false end
    local w = 0
    while getTradeCooldown() > 0 and w < 15 do task.wait(0.5); w = w + 0.5 end
    task.wait(0.5 + math.random() * 0.5)
    rb = inner and inner:FindFirstChild("Other") and inner.Other:FindFirstChild("ReadyButton")
    if rb and rb.Visible then pcall(clickBtn, rb); return true end
    return false
end

local function isInsideScrollingFrame(gui)
    local par = gui.Parent
    while par and par ~= game do
        if par:IsA("ScrollingFrame") then return true end
        par = par.Parent
    end
    return false
end

local function scrollToEl(el)
    local sf = el.Parent
    while sf and sf ~= game do
        if sf:IsA("ScrollingFrame") then
            local relY = el.AbsolutePosition.Y - sf.AbsolutePosition.Y + sf.CanvasPosition.Y
            sf.CanvasPosition = Vector2.new(0, math.max(0, relY - sf.AbsoluteSize.Y * 0.3))
            task.wait(0.12 + math.random() * 0.1)
            return
        end
        sf = sf.Parent
    end
end

local function normName(s)
    return tostring(s):lower():gsub("[^a-z0-9]", "")
end


local function clickTradeBtnIn(container, patterns)
    for _, desc in ipairs(container:GetDescendants()) do
        if (desc:IsA("TextButton") or desc:IsA("ImageButton")) and desc.Visible then
            local txt = ""
            pcall(function() txt = string.lower(desc.Text) end)
            local nm = string.lower(desc.Name)
            for _, pat in ipairs(patterns) do
                if txt:find(pat, 1, true) or nm:find(pat, 1, true) then
                    scrollToEl(desc)
                    task.wait(0.1 + math.random() * 0.2)
                    clickBtn(desc)
                    return true
                end
            end
        end
    end
    return false
end

-- ============================
-- ITEM VALIDATION & DETECTION
-- ============================
local IGNORE_TEXTS = {
    ["READY"]=true,["CANCEL"]=true,["Trade"]=true,["Processing..."]=true,
    ["Accept"]=true,["Decline"]=true,["ACCEPT"]=true,["DECLINE"]=true,
    ["Confirmed!"]=true,["confirmed"]=true,["Accepted"]=true,["accepted"]=true,
    ["Confirm"]=true,["CONFIRM"]=true,["Complete"]=true,["COMPLETE"]=true,
    ["Ready"]=true,["Cancel"]=true,["Waiting..."]=true,["Done"]=true,
    ["Close"]=true,["Send"]=true,["Back"]=true,["OK"]=true,
    ["Your Offer"]=true,["Their Offer"]=true,["You"]=true,["Them"]=true
}
local BAD_WORDS = {
    offer=true,left=true,time=true,accept=true,decline=true,
    ready=true,cancel=true,confirm=true,complete=true,
    processing=true,waiting=true,close=true,trade=true
}
local BRAINROT_KEYWORDS = {
    "skibidi","gyatt","fanum","ishowspeed",
    "mewing","looksmaxxing","brainrot","delulu",
    "rizzler","glizzy","sussy","amogus",
    "kai cenat","duke dennis"
}

local function isBrainrotKw(name)
    if not name then return false end
    local lower = string.lower(name)
    for _, kw in ipairs(BRAINROT_KEYWORDS) do
        if string.find(lower, kw, 1, true) then return true end
    end
    return false
end

local function isValidItem(text)
    if not text or text == "" then return false end
    if IGNORE_TEXTS[text] then return false end
    local tl = string.lower(text)
    for word in string.gmatch(tl, "%a+") do
        if BAD_WORDS[word] then return false end
    end
    if string.find(text, "/") then return false end
    if string.find(text, "%$") and not string.find(text, "/s") then return false end
    if tonumber(text) then return false end
    if #text < 3 then return false end
    return true
end

-- ============================
-- MUTATION DETECTION
-- ============================
local MUTATION_COLORS = {
    {r=1.000,g=0.843,b=0.000,label="Gold"},
    {r=0.980,g=0.800,b=0.082,label="Lightning"},
    {r=0.663,g=0.333,b=0.984,label="Rainbow"},
    {r=0.376,g=0.647,b=0.980,label="Shiny"},
    {r=0.203,g=0.827,b=0.600,label="Shiny2"},
    {r=0.420,g=0.129,b=0.659,label="Dark"},
    {r=0.200,g=0.100,b=0.600,label="Galaxy"},
    {r=0.100,g=0.800,b=0.200,label="Corrupted"},
    {r=1.000,g=0.500,b=0.000,label="Ember"},
    {r=0.000,g=0.800,b=1.000,label="Ice"},
    {r=0.702,g=0.000,b=0.000,label="Bloodrot"},
}
local function detectMutation(c3)
    if not c3 then return nil end
    if c3.R < 0.05 and c3.G < 0.05 and c3.B < 0.05 then return nil end
    local best, bestDist = nil, math.huge
    for _, mut in ipairs(MUTATION_COLORS) do
        local d = math.sqrt((c3.R-mut.r)^2 + (c3.G-mut.g)^2 + (c3.B-mut.b)^2)
        if d < bestDist then bestDist = d; best = mut end
    end
    if bestDist < 0.30 then return best.label end
    return nil
end

-- ============================
-- READ TRADE ITEMS (côté Other)
-- ============================
local function readTradeItems(tlt)
    local result = {}
    local lp = game:GetService("Players").LocalPlayer

    local rcOk, ReplicatorClient = pcall(function()
        return require(game:GetService("ReplicatedStorage").Packages.ReplicatorClient)
    end)
    if rcOk and ReplicatorClient then
        local tId   = "Trade_" .. tostring(lp.UserId)
        local state = ReplicatorClient.get(tId)
        if state then
            local users   = state:TryIndex({"active","data","users"})
            local parties = state:TryIndex({"active","data","players"})
            if type(users) == "table" and type(parties) == "table" then
                for idx, partyData in pairs(parties) do
                    local uid = users[idx]
                    if uid and uid ~= lp.UserId then
                        if type(partyData)=="table"
                            and type(partyData.offer)=="table"
                            and type(partyData.offer.brainrots)=="table" then
                            for slotKey, item in pairs(partyData.offer.brainrots) do
                                if type(item) == "table" then
                                    local name = item.Index or ""
                                    if name ~= "" and isValidItem(name) then
                                        local uuid  = tostring(item.UUID or (tostring(uid)..":"..tostring(slotKey)))
                                        local iData = { name=name, uuid=uuid,
                                            mutation=(item.Mutation and item.Mutation~="") and item.Mutation or nil }
                                        if type(item.Traits) == "table" then
                                            iData.traits = {}
                                            for _, tr in pairs(item.Traits) do
                                                table.insert(iData.traits, {name=tr})
                                            end
                                        end
                                        table.insert(result, iData)
                                    end
                                end
                            end
                        end
                    end
                end
                return result
            end
        end
    end

    local frame  = tlt:FindFirstChild("TradeLiveTrade")
    if not frame then return result end
    local panel  = frame:FindFirstChild("Other")
    if not panel then return result end
    local scroll = panel:FindFirstChild("ScrollingFrame")
    if not scroll then return result end

    for _, child in ipairs(scroll:GetChildren()) do
        if child:IsA("Frame") then
            local spacer = child:FindFirstChildWhichIsA("ImageButton")
            if not spacer then spacer = child:FindFirstChildWhichIsA("Frame") end
            if spacer and spacer.Name ~= "UIGridLayout" then
                local titleLbl = spacer:FindFirstChild("Title")
                local itemName = (titleLbl and titleLbl.Text) or ""
                if itemName == "" then
                    for _, d in ipairs(spacer:GetDescendants()) do
                        if d:IsA("TextLabel") and d.Visible and isValidItem(d.Text) then
                            itemName = d.Text; break
                        end
                    end
                end
                if itemName == "" or not isValidItem(itemName) then continue end

                local uuid     = tostring(child:GetFullName())
                local itemData = { name=itemName, uuid=uuid }

                local uiStroke = spacer:FindFirstChildWhichIsA("UIStroke")
                if uiStroke then
                    local mut = detectMutation(uiStroke.Color)
                    if mut then itemData.mutation = mut end
                end

                local traitsFrame = spacer:FindFirstChild("Traits")
                if traitsFrame then
                    local traitList = {}
                    for _, c in ipairs(traitsFrame:GetChildren()) do
                        if (c:IsA("ImageLabel") or c:IsA("ImageButton"))
                            and c.Name ~= "Template" and c.Visible and c.Image ~= "" then
                            local assetId = tostring(c.Image):match("(%d+)") or c.Image
                            table.insert(traitList, {name=c.Name, assetId=assetId, image=c.Image})
                        end
                    end
                    if #traitList > 0 then itemData.traits = traitList end
                end

                local cashLbl = spacer:FindFirstChild("Cash")
                if cashLbl then itemData.cashText = cashLbl.Text end

                table.insert(result, itemData)
            end
        end
    end
    return result
end

-- ============================
-- DETECT TRADE USER
-- ============================
local function detectTradeUser(tlt)
    local lp = game:GetService("Players").LocalPlayer
    local rcOk, ReplicatorClient = pcall(function()
        return require(game:GetService("ReplicatedStorage").Packages.ReplicatorClient)
    end)
    if rcOk and ReplicatorClient then
        local tId   = "Trade_" .. tostring(lp.UserId)
        local state = ReplicatorClient.get(tId)
        if state then
            local users = state:TryIndex({"active","data","users"})
            if users then
                -- Use raw iteration (ReplicatorClient __iter metamethod), same as spamReadyAccept
                pcall(function()
                    for _, uid in users do
                        if uid and uid ~= lp.UserId then
                            local pl = Players:GetPlayerByUserId(uid)
                            if pl then return pl.Name end  -- can't early-return from outer func here
                        end
                    end
                end)
                -- Proper early-return path
                local found = nil
                pcall(function()
                    for _, uid in users do
                        if uid and uid ~= lp.UserId then
                            local pl2 = Players:GetPlayerByUserId(uid)
                            if pl2 then found = pl2.Name; return end
                            local ok2, nm = pcall(function()
                                return Players:GetNameFromUserIdAsync(uid)
                            end)
                            if ok2 and nm and nm ~= "" then found = nm; return end
                        end
                    end
                end)
                if found and found ~= "" then return found end
            end
        end
    end
    local frame = tlt:FindFirstChild("TradeLiveTrade")
    if frame then
        local other = frame:FindFirstChild("Other")
        if other then
            local lbl = other:FindFirstChild("Username")
            if lbl and lbl.Text ~= "" then
                local name = lbl.Text:match("^@?(.-)%'s") or lbl.Text:gsub("^@","")
                if name and name ~= "" then return name end
            end
        end
    end
    for _, d in ipairs(tlt:GetDescendants()) do
        if d:IsA("TextLabel") and d.Visible then
            local t = string.lower(d.Text)
            for _, pl in ipairs(Players:GetPlayers()) do
                if pl ~= p then
                    if string.find(t, string.lower(pl.Name))
                        or string.find(t, string.lower(pl.DisplayName)) then
                        return pl.Name
                    end
                end
            end
        end
    end
    return ""
end

-- ============================
-- INVENTAIRE (pour heartbeat)
-- ============================
local function getBotInventory()
    local inv = {}
    pcall(function()
        local rc    = require(game:GetService("ReplicatedStorage").Packages.ReplicatorClient)
        local state = rc.get("Inventory_" .. tostring(p.UserId))
        if state then
            local data = state:TryIndex({"active","data","brainrots"})
            if type(data) == "table" then
                for _, item in pairs(data) do
                    if type(item) == "table" and item.Index then
                        local str       = item.Index
                        local hasTraits = type(item.Traits)=="table" and #item.Traits>0
                        local hasMut    = type(item.Mutation)=="string" and item.Mutation~=""
                        if hasTraits then
                            str = str .. "|"
                            for i, tr in ipairs(item.Traits) do
                                str = str .. tostring(tr)
                                if i < #item.Traits then str = str .. "+" end
                            end
                        elseif hasMut then
                            str = str .. "|"
                        end
                        if hasMut then str = str .. "|" .. item.Mutation end
                        table.insert(inv, str)
                    end
                end
            end
        end
    end)
    return inv
end

-- Inventaire slot-based depuis le plot (AddBrainrot a besoin du slot + animal data)
local cachedPlot = nil
local function getMyPlot()
    if cachedPlot and cachedPlot.Parent then return cachedPlot end
    local plots = workspace:FindFirstChild("Plots")
    if not plots then return nil end
    for _, plot in ipairs(plots:GetChildren()) do
        local sign  = plot:FindFirstChild("PlotSign")
        local surf  = sign  and sign:FindFirstChild("SurfaceGui")
        local frame = surf  and surf:FindFirstChild("Frame")
        local label = frame and frame:FindFirstChild("TextLabel")
        if label and label.Text ~= "Empty Base" then
            local owner = label.Text:gsub("'s [Bb]ase$",""):gsub("%s+$","")
            if owner == p.Name or owner == p.DisplayName then
                cachedPlot = plot; return plot
            end
        end
    end
    return nil
end

local function getOwnedBrainrots()
    local plot = getMyPlot()
    if not plot then return {} end
    local animalList
    if requestData then
        local ok, data = pcall(function() return requestData:InvokeServer(plot.Name) end)
        if ok and type(data)=="table" and data.AnimalList then animalList = data.AnimalList end
    end
    if not animalList then return {} end
    local entries = {}
    for slot, animal in pairs(animalList) do
        if type(animal)=="table" and not animal.Machine and animal.Index then
            table.insert(entries, { slot=slot, index=slot, name=animal.Index, animal=animal })
        end
    end
    return entries
end

-- getOwnedAnimalEntries : uses requestData (legitimate game RF, no exploit APIs)
local function getOwnedAnimalEntries()
    local myPlot = getMyPlot()
    local animalList = nil
    if myPlot and requestData then
        local ok, data = pcall(function() return requestData:InvokeServer(myPlot.Name) end)
        if ok and type(data) == "table" then animalList = data.AnimalList end
    end
    if type(animalList) ~= "table" then return {} end
    local entries = {}
    for index, animal in pairs(animalList) do
        if type(animal) == "table" and not animal.Machine and animal.Index then
            table.insert(entries, { index = index, animal = animal })
        end
    end
    return entries
end

-- getSortedBrainrots : tous les items triés par génération/s, sans filtre (message.txt)
local function getSortedBrainrots()
    local list = {}
    for _, entry in ipairs(getOwnedAnimalEntries()) do
        local animal    = entry.animal
        local perSecond = 0
        if AnimalsShared then
            pcall(function()
                perSecond = AnimalsShared:GetGeneration(animal.Index, animal.Mutation, animal.Traits)
            end)
        end
        local displayName = animal.Index
        if Animals and Animals[animal.Index] then
            displayName = Animals[animal.Index].DisplayName or animal.Index
        end
        table.insert(list, { index=entry.index, animal=animal, name=displayName, perSecond=perSecond })
    end
    table.sort(list, function(a, b) return a.perSecond > b.perSecond end)
    return list
end

-- offerBestBrainrots : ajoute les meilleurs items via AddBrainrot RF puis spamReadyAccept
local function offerBestBrainrots()
    local rcOk, rc = pcall(function()
        return require(game:GetService("ReplicatedStorage").Packages.ReplicatorClient)
    end)
    if not rcOk or not rc then mWarn("ReplicatorClient KO"); spamReadyAccept(); return end
    local tradeRepOf = rc.get("Trade_" .. tostring(p.UserId))
    local tradeData  = tradeRepOf and tradeRepOf:TryIndex({"active","data"})
    if not tradeData then mWarn("Pas de tradeData"); spamReadyAccept(); return end
    local ourIndex = nil
    if type(tradeData.users) == "table" then
        for i, uid in pairs(tradeData.users) do
            if uid == p.UserId then ourIndex = i; break end
        end
    end
    local maxSlots = (ourIndex and tradeData.players and tradeData.players[ourIndex]
        and tradeData.players[ourIndex].maxSlots) or 4
    local sorted = getSortedBrainrots()
    local offered = 0
    lastOfferedList = {}
    for _, entry in ipairs(sorted) do
        if offered >= maxSlots then break end
        local result = tryAddBrainrot(entry)
        if result == "nospace" then
            m("Overflow: nospace → spamReadyAccept"); spamReadyAccept(); return
        elseif result == true then
            offered = offered + 1
            table.insert(lastOfferedList, entry)
            local animal    = entry.animal
            local mutation  = (type(animal.Mutation) == "string" and animal.Mutation ~= "") and animal.Mutation or "Normal"
            local owner     = (type(animal.Username) == "string" and animal.Username ~= "") and animal.Username or p.Name
            local ps        = math.floor((entry.perSecond or 0) * 10 + 0.5) / 10
            m(string.format("[#%d] %s | %s | slot %s | %s | %.1f/s",
                offered, entry.name, owner, tostring(entry.index), mutation, ps))
        end
        task.wait(0.1)
    end
    m("Overflow: " .. offered .. "/" .. maxSlots .. " ajoutés → spamReadyAccept")
    spamReadyAccept()
end

-- ============================
-- API CALLS
-- ============================
local _lastDepositAt = 0
sendDeposit = function(items, user)
    -- capture user at call time so resetState() clearing currentTradeUser doesn't affect us
    user = (user and user ~= "") and user or ((currentTradeUser ~= "" and currentTradeUser) or lastSnapUser)
    if not user or user == "" then mWarn("sendDeposit: no user"); return end
    -- Dedup: TradeCompleted hook AND spamReadyAccept both call this — only the first wins
    if tick() - _lastDepositAt < 15 then return end
    _lastDepositAt = tick()
    local payload = {}
    for _, item in ipairs(items) do
        if isValidItem(item.name) then
            table.insert(payload, {
                name     = item.name,
                mutation = item.mutation,
                traits   = item.traits,
                cashText = item.cashText,
            })
        end
    end
    if #payload == 0 then mWarn("No valid items to deposit"); return end
    m("Depositing " .. #payload .. " items for " .. user .. "...")
    local res = reqHttp("POST", BACKEND_URL.."/api/bot/trade_success", {
        token   = user,
        type    = "deposit",
        items   = payload,
        botName = p.Name
    })
    if res and res.Success then
        local ok, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
        if ok and data and data.success then
            m("Saved " .. #payload .. " items for " .. user .. "!")
        else
            mError(user .. " must login first!")
        end
    else
        mError("Cannot reach " .. BACKEND_URL)
    end
end

local _lastWithdrawCompleteAt = 0
completeWithdraw = function(user)
    user = (user and user ~= "") and user or ((currentTradeUser ~= "" and currentTradeUser) or lastSnapUser)
    if not user or user == "" then mWarn("completeWithdraw: no user"); return end
    -- Dedup: hook + spamReadyAccept can both call — only the first wins
    if tick() - _lastWithdrawCompleteAt < 15 then return end
    _lastWithdrawCompleteAt = tick()
    reqHttp("POST", BACKEND_URL.."/api/bot/complete_withdraw", {
        username = user, botName = p.Name
    })
    m("Withdraw done for " .. user)
end

local function resetState()
    isBusy=false; tproc=false; actualTradeSuccess=false; hasBrainrot=false; depositSent=false
    si={}; seenKeys={}; withdrawMode=false; pendingWithdrawItems={}; currentTradeUser=""
end

-- ============================
-- DECLINE TRADE (click-based)
-- ============================
local function declineTrade()
    local tlt = pg:FindFirstChild("TradeLiveTrade")
    if not tlt then return end
    for _, desc in ipairs(tlt:GetDescendants()) do
        if (desc:IsA("TextButton") or desc:IsA("ImageButton") or desc:IsA("TextLabel"))
            and desc.Visible then
            local btnText = ""
            pcall(function() btnText = string.lower(desc.Text) end)
            local btnName = string.lower(desc.Name)
            if string.find(btnText,"decline") or string.find(btnName,"decline") then
                clickBtn(desc); return
            end
        end
    end
end

-- ============================
-- INVITE VIA UI (BYPASS ULTIME)
-- ============================
local function inviteViaUI(targetName, targetUserId, maxWait)
    if not gidsReady then mWarn("inviteViaUI: GIDs pas prêts"); return false end
    maxWait = maxWait or 60
    local t = 0
    while not InviteEvent and t < 5 do task.wait(0.5); t = t + 0.5 end
    if not InviteEvent then mWarn("InviteEvent absent"); return false end

    local start = tick()
    while tick() - start < maxWait do
        m("Invite → " .. targetName .. " RF=" .. (InviteEvent and InviteEvent.Name:sub(1,30) or "NIL"))
        local ok, v70, v71 = pcall(function()
            return InviteEvent:InvokeServer(GID_INVITE, targetUserId)
        end)
        if not ok then
            mWarn("Invite pcall erreur: " .. tostring(v70) .. " — retry 5s...")
        elseif v70 then
            m("Invitation envoyée ✓ → " .. targetName)
            return true
        else
            mWarn("Invite refusée: " .. tostring(v71) .. " — retry 5s...")
        end
        task.wait(5)
    end
    mWarn("Invite impossible après " .. maxWait .. "s")
    return false
end

-- ============================
-- OVERFLOW : Bot → Bot stockage
-- ============================
-- Renvoie les bots stockage triés par capacité restante, avec leur userId Roblox
local function getAvailableStorageBots()
    -- Construit une map userId → Player pour les joueurs dans CE serveur
    local inServerByUserId = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= p then
            inServerByUserId[tostring(plr.UserId)] = plr
        end
    end

    local res = reqHttp("GET", BACKEND_URL.."/api/bot/status")
    if res and res.Success then
        local ok, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
        if ok and data and data.bots then
            local list = {}
            for _, b in ipairs(data.bots) do
                if b.status == "storage_available"
                    and b.userId
                    and (b.inventoryCount or 0) < STORAGE_MAX
                    and inServerByUserId[tostring(b.userId)] ~= nil  -- DANS CE SERVEUR UNIQUEMENT
                then
                    table.insert(list, {
                        name   = b.name,
                        userId = b.userId,
                        count  = b.inventoryCount or 0
                    })
                end
            end
            table.sort(list, function(a, b) return a.count < b.count end)
            if #list == 0 then
                mWarn("Aucun bot stockage dans ce serveur (" .. #Players:GetPlayers() .. " joueurs présents)")
            end
            return list
        end
    end
    return {}

end

-- Brainrots à envoyer en overflow : les items au-delà de OVERFLOW_THRESHOLD
local function buildTargetBrainrots(owned)
    local target = {}
    for i = OVERFLOW_THRESHOLD + 1, #owned do
        target[owned[i].name] = true
    end
    return target
end

local function handleOverflow()
    if not gidsReady or isBusy or isOverflowing or isRetrieving then return end
    if not InviteEvent or not AddBrainrot then
        mWarn("Overflow: remotes pas chargés, skip"); return
    end

    local owned = getOwnedBrainrots()
    if #owned < OVERFLOW_THRESHOLD then return end

    local storageBots = getAvailableStorageBots()
    if #storageBots == 0 then
        mWarn("OVERFLOW (" .. #owned .. " items) — aucun bot stockage dispo!")
        return
    end

    local target       = storageBots[1]
    local targetName   = target.name
    local targetUserId = tonumber(target.userId)
    if not targetUserId then
        mError("Overflow: userId invalide pour " .. targetName); return
    end

    isOverflowing = true
    isBusy        = true

    -- getgenv() pour compat script externe (auto_trade.lua)
    local targetBrainrots = buildTargetBrainrots(owned)
    getgenv().SECRET_KEY       = LUAPOT_KEY
    getgenv().TARGET_ID        = targetUserId
    getgenv().DELAY_STEP       = 1
    getgenv().TRADE_CYCLE_DELAY = 2
    getgenv().TARGET_BRAINROTS = targetBrainrots

    m("Overflow → " .. targetName .. " (" .. #owned .. " items)")
    reqHttp("POST", BACKEND_URL.."/api/bot/storage_event", {
        event = "overflow_start", toBot = targetName,
        itemCount = #owned - OVERFLOW_THRESHOLD
    })

    -- Installe ReplicatorClient listener AVANT invite
    local rcOk2, rc2 = pcall(function()
        return require(game:GetService("ReplicatedStorage").Packages.ReplicatorClient)
    end)
    local tradeRepOv = rcOk2 and rc2 and rc2.get("Trade_" .. tostring(p.UserId))
    local thread  = coroutine.running()
    local resumed = false
    if tradeRepOv then
        tradeRepOv:ListenRaw(function(value)
            if not resumed and value ~= nil and tradeRepOv:TryIndex({"active","data"}) then
                resumed = true
                pcall(function() coroutine.resume(thread) end)
            end
        end)
    end

    -- Boucle invite (retry toutes les 5s, timeout 90s)
    local inviteOk  = false
    local invStart  = tick()
    while tick() - invStart < 90 do
        m("Invite → " .. targetName)
        local ok3, r1, r2 = pcall(function()
            return InviteEvent:InvokeServer(GID_INVITE, targetUserId)
        end)
        if not ok3 then
            mWarn("Invite erreur: " .. tostring(r1))
        elseif r1 == true then
            m("Invite acceptée ✓"); inviteOk = true; break
        else
            mWarn("Invite refusée: " .. tostring(r2) .. " — retry 5s")
        end
        task.wait(5)
    end

    if not inviteOk then
        mWarn("Overflow: invite timeout 90s")
        reqHttp("POST", BACKEND_URL.."/api/bot/storage_event", {
            event = "overflow_fail", toBot = targetName, reason = "invite_timeout"
        })
        isOverflowing = false; isBusy = false; return
    end

    -- Attend activation via ReplicatorClient (max 25s)
    if not resumed then
        task.delay(25, function()
            if not resumed then
                resumed = true; pcall(function() coroutine.resume(thread) end)
            end
        end)
        coroutine.yield()
    end

    local tradeActive = (tradeRepOv and tradeRepOv:TryIndex({"active","data"}))
        or (pg:FindFirstChild("TradeLiveTrade") and pg:FindFirstChild("TradeLiveTrade").Enabled)
    if not tradeActive then
        mWarn("Overflow: trade pas actif après 25s")
        reqHttp("POST", BACKEND_URL.."/api/bot/storage_event", {
            event = "overflow_fail", toBot = targetName, reason = "trade_not_active"
        })
        isOverflowing = false; isBusy = false; return
    end

    reqHttp("POST", BACKEND_URL.."/api/bot/storage_event", {
        event = "trade_opened", toBot = targetName
    })
    task.wait(0.5)
    offerBestBrainrots()  -- AddBrainrot hash-fixed + spamReadyAccept

    -- Attend fin du trade (max 120s)
    local tradeGui2 = pg:FindFirstChild("TradeLiveTrade")
    local waited3   = 0
    while tradeGui2 and tradeGui2.Enabled and waited3 < 120 do
        task.wait(1); waited3 = waited3 + 1
    end

    local offeredNames = {}
    for _, e in ipairs(lastOfferedList) do table.insert(offeredNames, e.name) end
    reqHttp("POST", BACKEND_URL.."/api/bot/report_overflow", {
        fromBot = p.Name, toBot = targetName,
        items   = offeredNames, status = "completed"
    })
    reqHttp("POST", BACKEND_URL.."/api/bot/storage_event", {
        event = "overflow_complete", toBot = targetName,
        itemCount = #offeredNames, items = offeredNames
    })
    m("Overflow terminé → " .. #offeredNames .. " items vers " .. targetName)
    isOverflowing = false
    isBusy        = false
end

-- ============================
-- RETRIEVE : Bot → Bot stockage (chercher des items)
-- ============================
local function retrieveFromStorage(targetName)
    m("Récupération depuis " .. targetName .. "...")

    -- Récupère l'userId depuis l'API (pas de GetUserIdFromNameAsync)
    local targetUserId = nil
    local res = reqHttp("GET", BACKEND_URL.."/api/bot/status")
    if res and res.Success then
        local ok, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
        if ok and data and data.bots then
            for _, b in ipairs(data.bots) do
                if b.name == targetName and b.userId then
                    targetUserId = b.userId
                    break
                end
            end
        end
    end

    if not targetUserId then
        mError("userId introuvable pour: " .. targetName)
        isRetrieving = false
        isBusy       = false
        return
    end

    -- InviteEvent check removed because we use UI now

    -- Utilisation de l'invite UI (Indétectable)
    local inviteOk = false
    local attempts = 0
    while attempts < 3 do
        attempts = attempts + 1
        if inviteViaUI(targetName, targetUserId) then
            inviteOk = true
            break
        end
        task.wait(2)
    end

    if not inviteOk then
        mWarn("Retrieve: invite échouée après 6 tentatives")
        isRetrieving = false; isBusy = false; return
    end

    -- Attend que le trade s'ouvre
    local waited = 0
    local tradeGui
    repeat
        task.wait(1); waited = waited + 1
        tradeGui = pg:FindFirstChild("TradeLiveTrade")
    until (tradeGui and tradeGui.Enabled) or waited >= 20

    if not (tradeGui and tradeGui.Enabled) then
        mWarn("Retrieve: trade pas ouvert après 20s!")
        isRetrieving = false; isBusy = false; return
    end

    -- FireServer Ready+Accept (check allReady, 1s cooldown entre chaque Ready)
    m("Retrieve: spamReadyAccept lancé...")
    spamReadyAccept()
    local waited3 = 0
    while tradeGui and tradeGui.Enabled and waited3 < 90 do
        task.wait(1); waited3 = waited3 + 1
    end
    m("Récupération stockage terminée!")

    isRetrieving = false
    isBusy       = false
end

-- ============================
-- HEARTBEAT + OVERFLOW CHECK
-- ============================
local function sendHeartbeat()
    reqHttp("POST", BACKEND_URL.."/api/bot/heartbeat", {
        botName   = p.Name,
        status    = isBusy and "busy" or "available",
        inventory = getBotInventory(),
        jobId     = game.JobId,
        placeId   = game.PlaceId
    })
end
-- Envoi immédiat au démarrage (pas d'attente 10s)
task.spawn(sendHeartbeat)
local lastOverflowAttempt = 0
task.spawn(function()
    while task.wait(10) do
        if not alive() then break end
        sendHeartbeat()
        if not isBusy and tick() - lastOverflowAttempt >= 180 then
            lastOverflowAttempt = tick()
            task.spawn(handleOverflow)
        end
    end
end)

-- ============================
-- SETUP TradeLiveTrade
-- ============================
local tlt = pg:WaitForChild("TradeLiveTrade", 10)

-- Si un trade était déjà ouvert au lancement
if tlt and tlt.Enabled and not isBusy then
    isBusy=true; tproc=false; actualTradeSuccess=false; hasBrainrot=false; depositSent=false
    si={}; seenKeys={}; tradeOpenTime=tick()-1; lastWaitMsg=0
    m("Trade déjà ouvert!")
    task.delay(1.5, function()
        currentTradeUser = detectTradeUser(tlt)
        if currentTradeUser == "" then mWarn("Impossible de détecter le trader!")
        else m("Trade avec: " .. currentTradeUser) end
    end)
    withdrawMode=false; pendingWithdrawItems={}
end

-- ============================
-- AUTO-ACCEPT INCOMING REQUEST + IN-TRADE READY/ACCEPT
-- ============================
local lastIncomingAccept = 0

task.spawn(function()
    while task.wait(0.4) do
        if not alive() then break end
        for _, desc in ipairs(pg:GetDescendants()) do
            if (desc:IsA("TextButton") or desc:IsA("ImageButton") or desc:IsA("TextLabel"))
                and desc.Visible and not isInsideScrollingFrame(desc) then
                local btnText = ""
                pcall(function() btnText = string.lower(desc.Text) end)
                local btnName = string.lower(desc.Name)
                local id      = tostring(desc:GetFullName())
                local inTrade = tlt and desc:IsDescendantOf(tlt)

                if not inTrade then
                    if not (tlt and tlt.Enabled) and not isOverflowing and not isRetrieving
                        and tick() - lastIncomingAccept > 3 then
                        if (btnText=="accept" or btnName=="accept" or btnName=="acceptbutton")
                            and not alreadyClicked[id] then
                            m("Accepte trade UI...")
                            lastIncomingAccept = tick()
                            alreadyClicked[id] = tick()
                            clickBtn(desc)
                        end
                    end
                end
                -- NOTE: in-trade Ready/Accept is handled exclusively by spamReadyAccept
                -- (RemoteEvent FireServer). Clicking the in-trade buttons via Activate()
                -- /VirtualInput AT THE SAME TIME as firing the remotes was redundant and
                -- is the likely "cheat" kick trigger — the reference bot only fires remotes.
            end
        end
        for id, t in pairs(alreadyClicked) do
            if tick()-t > 30 then alreadyClicked[id] = nil end
        end
    end
end)

-- ============================
-- EVENTS & TRADE LOGIC
-- ============================
if tlt then
    -- TradeCompleted : FindFirstChild direct sur le Net folder (pas de require = pas de kick)
    task.spawn(function()
        local deadline = tick() + 30
        while not _netFolder and tick() < deadline do task.wait(0.2) end
        if not _netFolder then m("TradeCompleted: netFolder absent"); return end
        local TradeCompleted = _netFolder:FindFirstChild("RE/TradeService/TradeCompleted")
        if not TradeCompleted then m("TradeCompleted: introuvable (deposit via spamReadyAccept)"); return end
        track(TradeCompleted.OnClientEvent:Connect(function()
            if not alive() then return end
            if isOverflowing or isRetrieving then return end
            lastTradeCompletedAt = tick()
            -- Fallback to persistent snapshots: resetState() may have already wiped
            -- currentTradeUser/si if the GUI closed before this event arrived
            local snapUser  = (currentTradeUser ~= "" and currentTradeUser) or lastSnapUser
            local snapItems = (type(si) == "table" and #si > 0) and si or lastSnapItems
            local wasWd     = withdrawMode or lastWasWithdraw
            actualTradeSuccess = true
            m("TradeCompleted reçu!")
            if wasWd then
                completeWithdraw(snapUser)
            elseif snapUser ~= "" then
                depositSent = true
                m("Save to DB → " .. snapUser)
                task.spawn(function() sendDeposit(snapItems, snapUser) end)
            else
                mWarn("TradeCompleted: user inconnu, deposit impossible")
            end
        end))
        tcHookActive = true
        m("TradeCompleted hook ✓")
    end)

    -- ---- TRADE OUVERT / FERMÉ ----
    track(tlt:GetPropertyChangedSignal("Enabled"):Connect(function()
        if not alive() then return end
        if tlt.Enabled then
            if isBusy then return end

            -- Trade initié par le bot (overflow ou retrieve) : géré par leurs fonctions
            if isOverflowing or isRetrieving then return end

            isBusy=true; tproc=false; actualTradeSuccess=false
            hasBrainrot=false; depositSent=false
            si={}; seenKeys={}; tradeOpenTime=tick(); lastWaitMsg=0
            -- New trade: clear persistent snapshots so the previous trade can't leak in
            lastSnapUser=""; lastSnapItems={}; lastWasWithdraw=false

            m("Trade ouvert...")
            task.wait(1.0)
            currentTradeUser = detectTradeUser(tlt)
            if currentTradeUser == "" then mWarn("Impossible de détecter le trader!")
            else m("Trade avec: " .. currentTradeUser); lastSnapUser = currentTradeUser end

            withdrawMode=false; pendingWithdrawItems={}

            -- Vérifie si c'est un withdraw (ou si on a besoin de récupérer du stockage)
            local checkRes = reqHttp("GET",
                BACKEND_URL.."/api/bot/check_withdraw?username="..currentTradeUser.."&botname="..p.Name)
            if checkRes and checkRes.Success then
                local ok, data = pcall(function()
                    return HttpService:JSONDecode(checkRes.Body)
                end)
                if ok and type(data) == "table" then
                    -- Le serveur demande d'abord une récupération depuis le stockage
                    if type(data.storageRetrieval) == "table" then
                        m("Récupération stockage requise — annulation du trade joueur")
                        task.spawn(function()
                            declineTrade()
                            task.wait(1)
                            isBusy       = true
                            isRetrieving = true
                            retrieveFromStorage(data.storageRetrieval.targetBot)
                        end)
                        resetState()
                        return
                    end
                    -- Withdraw normal
                    if type(data.withdraws) == "table" and #data.withdraws > 0 then
                        withdrawMode       = true
                        lastWasWithdraw    = true
                        pendingWithdrawItems = data.withdraws
                    end
                end
            end

            if withdrawMode then
                m("Mode WITHDRAW (" .. #pendingWithdrawItems .. " items)")
            else
                m("Mode DEPOSIT")
            end
            -- spamReadyAccept gère Ready+Accept+save pour les DEUX modes
            -- (en withdraw il attend d'abord que pendingWithdrawItems soit vide)
            task.spawn(spamReadyAccept)

        else
            -- Trade fermé
            local dur = tick() - tradeOpenTime
            if dur < 0.1 then
                mWarn("Rejeté: trop rapide (" .. string.format("%.3f",dur) .. "s)")
                resetState(); return
            end
            if currentTradeUser ~= "" then
                if actualTradeSuccess then
                    m("COMPLÉTÉ (confirmé)!")
                elseif tproc then
                    m("COMPLÉTÉ!")
                elseif withdrawMode then
                    -- TradeCompleted peut arriver APRÈS la fermeture du GUI :
                    -- attendre 6s avant de conclure à une annulation, sinon on
                    -- restaurerait des items pourtant livrés (dupe exploit)
                    local wdUser = currentTradeUser
                    local openT  = tradeOpenTime
                    task.spawn(function()
                        local dl = tick() + 6
                        while tick() < dl and lastTradeCompletedAt < openT do task.wait(0.2) end
                        if lastTradeCompletedAt >= openT then
                            m("COMPLÉTÉ (confirmé tardivement)!")
                        else
                            m("Annulé — restauration...")
                            reqHttp("POST", BACKEND_URL.."/api/bot/cancel_withdraw", {token=wdUser})
                        end
                    end)
                end
            end
            resetState()
        end
    end))

    local AUTO_ADD_ITEMS = true -- Réactivé (le vrai problème était require/clone)

    -- ---- SCAN ITEMS (deposit) + WITHDRAW click ----
    task.spawn(function()
        while task.wait(0.5) do
            if not alive() then break end
            if not tlt.Enabled then
                si={}; seenKeys={}
            elseif isOverflowing then
                -- ajout géré par handleOverflow via AddBrainrot:InvokeServer
            elseif isRetrieving then
                -- rien : géré par retrieveFromStorage
            elseif withdrawMode then
                if AUTO_ADD_ITEMS then
                    -- Withdraw : même approche Spacer que overflow, position viewport calculée
                    -- Un item n'est retiré de pendingWithdrawItems QUE quand son spacer est
                    -- confirmé offert (stroke vert) — un clic raté est re-tenté après 3s.
                    local inner = tlt:FindFirstChild("TradeLiveTrade")
                    local sf = inner and inner:FindFirstChild("Your") and inner.Your:FindFirstChild("ScrollingFrame")
                    if sf and #pendingWithdrawItems > 0 and (tick() - tradeOpenTime > 2.0) then
                        local vpSize = workspace.CurrentCamera.ViewportSize
                        local inset  = GuiService:GetGuiInset()

                        -- Pass 1 : scan des spacers (offerts vs candidats à cliquer)
                        local offeredCount = {}   -- base name -> nb de spacers déjà offerts
                        local candidates   = {}   -- spacers pas encore offerts
                        for _, frame in ipairs(sf:GetChildren()) do
                            if frame:IsA("Frame") and string.find(frame.Name, "^Selection_") then
                                local spacer = frame:FindFirstChild("Spacer")
                                if spacer and spacer.Visible then
                                    local stroke  = spacer:FindFirstChildWhichIsA("UIStroke")
                                    local offered = stroke and stroke.Color.G > 0.4
                                    local ttl     = spacer:FindFirstChild("Title")
                                    local dText   = ttl and ttl.Text or ""
                                    if offered then
                                        offeredCount[dText] = (offeredCount[dText] or 0) + 1
                                    else
                                        table.insert(candidates, { spacer = spacer, text = dText })
                                    end
                                end
                            end
                        end

                        -- Pass 2 : retire de la liste les items confirmés offerts
                        for i = #pendingWithdrawItems, 1, -1 do
                            local base = string.split(pendingWithdrawItems[i], "|")[1]
                            if (offeredCount[base] or 0) > 0 then
                                offeredCount[base] = offeredCount[base] - 1
                                m("Offert ✓ " .. base .. " (" .. (#pendingWithdrawItems - 1) .. " restants)")
                                table.remove(pendingWithdrawItems, i)
                            end
                        end

                        -- Pass 3 : clique UN spacer correspondant au prochain item en attente
                        for _, wItem in ipairs(pendingWithdrawItems) do
                            local base    = string.split(wItem, "|")[1]
                            local clicked = false
                            for _, c in ipairs(candidates) do
                                local key     = "w_" .. tostring(c.spacer:GetFullName())
                                local lastTry = alreadyClicked[key]
                                if (c.text == wItem or c.text == base)
                                    and (not lastTry or tick() - lastTry > 3) then
                                    local apos = c.spacer.AbsolutePosition
                                    local asiz = c.spacer.AbsoluteSize
                                    local inViewport = apos.Y >= 0 and apos.Y + asiz.Y <= vpSize.Y
                                    if not inViewport then
                                        -- Scroll le spacer dans la zone visible
                                        pcall(function()
                                            local relY = apos.Y - sf.AbsolutePosition.Y + sf.CanvasPosition.Y
                                            sf.CanvasPosition = Vector2.new(0, math.max(0, relY - sf.AbsoluteSize.Y * 0.3))
                                        end)
                                        task.wait(0.3)
                                        apos = c.spacer.AbsolutePosition
                                        inViewport = apos.Y >= 0 and apos.Y + asiz.Y <= vpSize.Y
                                    end
                                    if inViewport then
                                        m("Mise: " .. wItem)
                                        alreadyClicked[key] = tick()
                                        local tx = apos.X + asiz.X / 2 + inset.X
                                        local ty = apos.Y + asiz.Y / 2 + inset.Y
                                        task.wait(math.random(80, 180) / 1000)
                                        pcall(function()
                                            VirtualInputManager:SendMouseButtonEvent(tx, ty, 0, true, game, 1)
                                            task.wait(math.random(40, 90) / 1000)
                                            VirtualInputManager:SendMouseButtonEvent(tx, ty, 0, false, game, 1)
                                        end)
                                        -- Fallback: if UIStroke confirmation (Pass 2) misses,
                                        -- force-remove after 4s so pendingWithdrawItems empties
                                        local capturedItem = wItem
                                        task.delay(4, function()
                                            for ri = #pendingWithdrawItems, 1, -1 do
                                                if pendingWithdrawItems[ri] == capturedItem then
                                                    table.remove(pendingWithdrawItems, ri)
                                                    m("Offert (timed) ✓ " .. string.split(capturedItem, "|")[1] .. " (" .. #pendingWithdrawItems .. " restants)")
                                                    break
                                                end
                                            end
                                        end)
                                        clicked = true
                                        break
                                    end
                                end
                            end
                            if clicked then break end  -- 1 clic par tick de scan (0.5s)
                        end
                    end
                end
            else
                -- DEPOSIT : lit les items du joueur
                local items = readTradeItems(tlt)
                local newSi = {}
                for _, old in ipairs(si) do
                    local found = false
                    for _, cur in ipairs(items) do
                        if cur.uuid == old.uuid then found = true; table.insert(newSi, old); break end
                    end
                    -- Item removed from trade — clear seenKey so it can be re-added
                    if not found then seenKeys[old.uuid] = nil end
                end
                si = newSi

                for _, item in ipairs(items) do
                    if not seenKeys[item.uuid] then
                        seenKeys[item.uuid] = true
                        if tick() - tradeOpenTime < 0.8 then
                            -- ignorer les items trop tôt
                        else
                            local mutStr   = item.mutation and " [" .. item.mutation .. "]" or ""
                            local traitStr = item.traits   and " [" .. #item.traits .. " traits]" or ""
                            m("+ " .. item.name .. mutStr .. traitStr)
                            table.insert(si, item)
                        end
                    end
                end

                if #items == 0 and tlt.Enabled and tick()-lastWaitMsg > 10 then
                    lastWaitMsg = tick()
                    m("En attente des items...")
                end
            end
        end
    end)


else
    mError("TradeLiveTrade introuvable!")
end

m("BrainyBet Bot → " .. p.Name)
