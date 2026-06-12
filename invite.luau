-- Trade Invite Sender
task.spawn(function()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end

    ----------------------------------------------------------------
    -- Services
    ----------------------------------------------------------------
    local Services = setmetatable({}, {
        __index = function(self, name)
            local ok, cache = pcall(function()
                return cloneref(game:GetService(name))
            end)
            if ok then
                rawset(self, name, cache)
                return cache
            else
                error("Invalid Service: " .. tostring(name))
            end
        end,
    })

    local LocalPlayer = Services.Players.LocalPlayer

    ----------------------------------------------------------------
    -- Remote lookup
    ----------------------------------------------------------------
    local u2 = require(Services.ReplicatedStorage.Packages.Net:Clone())
    local function makeRemote(method, name)
        local remotename
        pcall(function()
            if method == "RemoteFunction" then
                remotename = u2:RemoteFunction(name)
            elseif method == "RemoteEvent" then
                remotename = u2:RemoteEvent(name)
            end
        end)
        
        if remotename then
            local targetName = typeof(remotename) == "Instance" and remotename.Name or tostring(remotename)
            return Services.ReplicatedStorage.Packages.Net:FindFirstChild(targetName, true)
        end
        return nil
    end

    local Invite = makeRemote("RemoteFunction", "TradeService/Invite")
    
    if not Invite then
        for _, child in ipairs(Services.ReplicatedStorage.Packages.Net:GetDescendants()) do
            if child:IsA("RemoteFunction") then
                local lname = child.Name:lower()
                if lname:find("invite") or lname:find("trade") then
                    Invite = child
                    break
                end
            end
        end
    end

    ----------------------------------------------------------------
    -- GUI
    ----------------------------------------------------------------
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "TradeInviteGui"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

    -- Main frame
    local frame = Instance.new("Frame")
    frame.Name = "Main"
    frame.Size = UDim2.new(0, 280, 0, 160)
    frame.Position = UDim2.new(0.5, -140, 0.5, -80)
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = screenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(80, 80, 120)
    stroke.Thickness = 1
    stroke.Parent = frame

    -- Title bar
    local titleBar = Instance.new("Frame")
    titleBar.Size = UDim2.new(1, 0, 0, 36)
    titleBar.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
    titleBar.BorderSizePixel = 0
    titleBar.Parent = frame

    local titleCorner = Instance.new("UICorner")
    titleCorner.CornerRadius = UDim.new(0, 8)
    titleCorner.Parent = titleBar

    -- Fix bottom corners of title bar
    local titleFix = Instance.new("Frame")
    titleFix.Size = UDim2.new(1, 0, 0, 8)
    titleFix.Position = UDim2.new(0, 0, 1, -8)
    titleFix.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
    titleFix.BorderSizePixel = 0
    titleFix.Parent = titleBar

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Size = UDim2.new(1, -40, 1, 0)
    titleLabel.Position = UDim2.new(0, 12, 0, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = "Trade Invite 1.5"
    titleLabel.TextColor3 = Color3.fromRGB(220, 220, 255)
    titleLabel.TextSize = 15
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Parent = titleBar

    -- Close button
    local closeBtn = Instance.new("TextButton")
    closeBtn.Size = UDim2.new(0, 26, 0, 26)
    closeBtn.Position = UDim2.new(1, -32, 0, 5)
    closeBtn.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
    closeBtn.BorderSizePixel = 0
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeBtn.TextSize = 13
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.Parent = titleBar

    local closeCorner = Instance.new("UICorner")
    closeCorner.CornerRadius = UDim.new(0, 5)
    closeCorner.Parent = closeBtn

    closeBtn.MouseButton1Click:Connect(function()
        screenGui:Destroy()
    end)

    -- User ID label
    local uidLabel = Instance.new("TextLabel")
    uidLabel.Size = UDim2.new(1, -24, 0, 18)
    uidLabel.Position = UDim2.new(0, 12, 0, 46)
    uidLabel.BackgroundTransparency = 1
    uidLabel.Text = "User ID"
    uidLabel.TextColor3 = Color3.fromRGB(160, 160, 200)
    uidLabel.TextSize = 12
    uidLabel.Font = Enum.Font.Gotham
    uidLabel.TextXAlignment = Enum.TextXAlignment.Left
    uidLabel.Parent = frame

    -- Input box
    local inputBox = Instance.new("TextBox")
    inputBox.Size = UDim2.new(1, -24, 0, 34)
    inputBox.Position = UDim2.new(0, 12, 0, 67)
    inputBox.BackgroundColor3 = Color3.fromRGB(35, 35, 50)
    inputBox.BorderSizePixel = 0
    inputBox.Text = ""
    inputBox.PlaceholderText = "Entrer un User ID..."
    inputBox.PlaceholderColor3 = Color3.fromRGB(90, 90, 110)
    inputBox.TextColor3 = Color3.fromRGB(230, 230, 255)
    inputBox.TextSize = 14
    inputBox.Font = Enum.Font.Gotham
    inputBox.ClearTextOnFocus = false
    inputBox.Parent = frame

    local inputCorner = Instance.new("UICorner")
    inputCorner.CornerRadius = UDim.new(0, 6)
    inputCorner.Parent = inputBox

    local inputStroke = Instance.new("UIStroke")
    inputStroke.Color = Color3.fromRGB(70, 70, 100)
    inputStroke.Thickness = 1
    inputStroke.Parent = inputBox

    -- Status label
    local statusLabel = Instance.new("TextLabel")
    statusLabel.Size = UDim2.new(1, -24, 0, 16)
    statusLabel.Position = UDim2.new(0, 12, 0, 105)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = ""
    statusLabel.TextColor3 = Color3.fromRGB(160, 160, 200)
    statusLabel.TextSize = 11
    statusLabel.Font = Enum.Font.Gotham
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.Parent = frame

    -- Send button
    local sendBtn = Instance.new("TextButton")
    sendBtn.Size = UDim2.new(1, -24, 0, 32)
    sendBtn.Position = UDim2.new(0, 12, 0, 118)
    sendBtn.BackgroundColor3 = Color3.fromRGB(70, 100, 220)
    sendBtn.BorderSizePixel = 0
    sendBtn.Text = "Envoyer l'invite"
    sendBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    sendBtn.TextSize = 14
    sendBtn.Font = Enum.Font.GothamBold
    sendBtn.Parent = frame

    local sendCorner = Instance.new("UICorner")
    sendCorner.CornerRadius = UDim.new(0, 6)
    sendCorner.Parent = sendBtn

    ----------------------------------------------------------------
    -- Logic
    ----------------------------------------------------------------
    local sending = false

    -- Indique si le remote a été trouvé
    if not Invite then
        statusLabel.Text = "Remote introuvable!"
        statusLabel.TextColor3 = Color3.fromRGB(220, 80, 80)
        sendBtn.BackgroundColor3 = Color3.fromRGB(80, 40, 40)
    end

    local function setStatus(msg, color)
        statusLabel.Text = msg
        statusLabel.TextColor3 = color or Color3.fromRGB(160, 160, 200)
    end

    sendBtn.MouseButton1Click:Connect(function()
        if sending then return end

        local raw = inputBox.Text:match("^%s*(.-)%s*$")
        local userId = tonumber(raw)

        if not userId then
            setStatus("ID invalide.", Color3.fromRGB(220, 80, 80))
            return
        end

        sending = true
        sendBtn.Text = "Envoi en cours..."
        sendBtn.BackgroundColor3 = Color3.fromRGB(50, 70, 150)
        setStatus("", Color3.fromRGB(160, 160, 200))

        task.spawn(function()
            setStatus("Envoi...", Color3.fromRGB(200, 160, 60))

            local ok, result = pcall(function()
                return Invite:InvokeServer(userId, "afb005f9-6e81-4e0a-8bb0-3555938a9658")
            end)

            print("[TradeInvite] OK:", ok, "| Result:", result, "| Type:", type(result))

            if ok then
                if result == nil or result == true or result == "Success" then
                    setStatus("Invite envoyée !", Color3.fromRGB(80, 200, 120))
                    sendBtn.Text = "Envoyée ✓"
                    sendBtn.BackgroundColor3 = Color3.fromRGB(50, 160, 80)
                else
                    local resStr = tostring(result)
                    setStatus("Resp: " .. resStr:sub(1, 35), Color3.fromRGB(220, 180, 80))
                    sendBtn.Text = "Serveur a répondu"
                    sendBtn.BackgroundColor3 = Color3.fromRGB(180, 120, 50)
                end
            else
                local msg = tostring(result):sub(1, 40)
                setStatus(msg, Color3.fromRGB(220, 80, 80))
                sendBtn.Text = "Erreur Call"
                sendBtn.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
            end

            task.wait(3)
            sendBtn.Text = "Envoyer l'invite"
            sendBtn.BackgroundColor3 = Color3.fromRGB(70, 100, 220)
            sending = false
        end)
    end)
end)
