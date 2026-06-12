-- Trade Invite Sender
task.spawn(function()
    if not game:IsLoaded() then
        game.Loaded:Wait()
    end
    task.wait(3)

    ----------------------------------------------------------------
    -- Services
    ----------------------------------------------------------------
    local Services = setmetatable({}, {
        __index = function(self, name)
            local svc = game:GetService(name)
            rawset(self, name, svc)
            return svc
        end,
    })

    local LocalPlayer = Services.Players.LocalPlayer

    ----------------------------------------------------------------
    -- Remote lookup (exactement comme loggertrade)
    ----------------------------------------------------------------
    local Net = Services.ReplicatedStorage.Packages.Net
    local u2 = require(Net)
    local remoteName = u2:RemoteFunction("TradeService/Invite")
    local Invite = Net:FindFirstChild(tostring(remoteName))

    ----------------------------------------------------------------
    -- GUI
    ----------------------------------------------------------------
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "TradeInviteGui"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 280, 0, 160)
    frame.Position = UDim2.new(0.5, -140, 0.5, -80)
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = screenGui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
    local stroke = Instance.new("UIStroke", frame)
    stroke.Color = Color3.fromRGB(80, 80, 120)
    stroke.Thickness = 1

    local titleBar = Instance.new("Frame")
    titleBar.Size = UDim2.new(1, 0, 0, 36)
    titleBar.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
    titleBar.BorderSizePixel = 0
    titleBar.Parent = frame
    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 8)
    local titleFix = Instance.new("Frame", titleBar)
    titleFix.Size = UDim2.new(1, 0, 0, 8)
    titleFix.Position = UDim2.new(0, 0, 1, -8)
    titleFix.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
    titleFix.BorderSizePixel = 0

    local titleLabel = Instance.new("TextLabel", titleBar)
    titleLabel.Size = UDim2.new(1, -40, 1, 0)
    titleLabel.Position = UDim2.new(0, 12, 0, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = "Trade Invite"
    titleLabel.TextColor3 = Color3.fromRGB(220, 220, 255)
    titleLabel.TextSize = 15
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left

    local closeBtn = Instance.new("TextButton", titleBar)
    closeBtn.Size = UDim2.new(0, 26, 0, 26)
    closeBtn.Position = UDim2.new(1, -32, 0, 5)
    closeBtn.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
    closeBtn.BorderSizePixel = 0
    closeBtn.Text = "✕"
    closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    closeBtn.TextSize = 13
    closeBtn.Font = Enum.Font.GothamBold
    Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)
    closeBtn.MouseButton1Click:Connect(function() screenGui:Destroy() end)

    local uidLabel = Instance.new("TextLabel", frame)
    uidLabel.Size = UDim2.new(1, -24, 0, 18)
    uidLabel.Position = UDim2.new(0, 12, 0, 46)
    uidLabel.BackgroundTransparency = 1
    uidLabel.Text = "User ID"
    uidLabel.TextColor3 = Color3.fromRGB(160, 160, 200)
    uidLabel.TextSize = 12
    uidLabel.Font = Enum.Font.Gotham
    uidLabel.TextXAlignment = Enum.TextXAlignment.Left

    local inputBox = Instance.new("TextBox", frame)
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
    Instance.new("UICorner", inputBox).CornerRadius = UDim.new(0, 6)
    local inputStroke = Instance.new("UIStroke", inputBox)
    inputStroke.Color = Color3.fromRGB(70, 70, 100)
    inputStroke.Thickness = 1

    local statusLabel = Instance.new("TextLabel", frame)
    statusLabel.Size = UDim2.new(1, -24, 0, 16)
    statusLabel.Position = UDim2.new(0, 12, 0, 105)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = ""
    statusLabel.TextColor3 = Color3.fromRGB(160, 160, 200)
    statusLabel.TextSize = 11
    statusLabel.Font = Enum.Font.Gotham
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left

    local sendBtn = Instance.new("TextButton", frame)
    sendBtn.Size = UDim2.new(1, -24, 0, 32)
    sendBtn.Position = UDim2.new(0, 12, 0, 118)
    sendBtn.BackgroundColor3 = Color3.fromRGB(70, 100, 220)
    sendBtn.BorderSizePixel = 0
    sendBtn.Text = "Envoyer l'invite"
    sendBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    sendBtn.TextSize = 14
    sendBtn.Font = Enum.Font.GothamBold
    Instance.new("UICorner", sendBtn).CornerRadius = UDim.new(0, 6)

    ----------------------------------------------------------------
    -- Logic
    ----------------------------------------------------------------
    local sending = false

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
        setStatus("Envoi...", Color3.fromRGB(200, 160, 60))

        task.spawn(function()
            local ok, result = pcall(function()
                return Invite:InvokeServer("afb005f9-6e81-4e0a-8bb0-3555938a9658", userId)
            end)

            print("[TradeInvite] ok=" .. tostring(ok) .. " result=" .. tostring(result))

            if ok and result then
                setStatus("Invite envoyée !", Color3.fromRGB(80, 200, 120))
                sendBtn.Text = "Envoyée ✓"
                sendBtn.BackgroundColor3 = Color3.fromRGB(50, 160, 80)
            else
                local msg = ok and ("result=" .. tostring(result)) or tostring(result):sub(1, 40)
                setStatus(msg, Color3.fromRGB(220, 80, 80))
                sendBtn.Text = "Envoyer l'invite"
                sendBtn.BackgroundColor3 = Color3.fromRGB(70, 100, 220)
            end

            task.wait(3)
            sendBtn.Text = "Envoyer l'invite"
            sendBtn.BackgroundColor3 = Color3.fromRGB(70, 100, 220)
            sending = false
        end)
    end)
end)
