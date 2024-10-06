local socket = require("socket")
local json = require("dkjson")
local http = require("socket.http")
local ltn12 = require("ltn12")

local ws = nil
local pingInterval = nil
local countdownInterval = nil
local potentialPoints = 0
local countdown = "Calculating..."
local pointsTotal = 0
local pointsToday = 0

local function readFile(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*all")
    file:close()
    return content
end

local function writeFile(path, content)
    local file = io.open(path, "w")
    if not file then return false end
    file:write(content)
    file:close()
    return true
end

local function getLocalStorage()
    local data = readFile("localStorage.json")
    if data then
        return json.decode(data)
    else
        return {}
    end
end

local function setLocalStorage(data)
    local currentData = getLocalStorage()
    for k, v in pairs(data) do
        currentData[k] = v
    end
    writeFile("localStorage.json", json.encode(currentData))
end

local function connectWebSocket(userId)
    if ws then return end
    local version = "v0.2"
    local url = "wss://secure.ws.teneo.pro"
    local wsUrl = string.format("%s/websocket?userId=%s&version=%s", url, userId, version)
    
    ws = socket.connect(wsUrl, 80)
    if not ws then
        print("Failed to connect WebSocket")
        return
    end

    print("WebSocket connected at", os.date())
    setLocalStorage({lastUpdated = os.date("!%Y-%m-%dT%H:%M:%SZ")})
    startPinging()
    startCountdownAndPoints()

    -- WebSocket message handling would go here
    -- This is a simplified version and doesn't include full WebSocket protocol implementation
end

local function disconnectWebSocket()
    if ws then
        ws:close()
        ws = nil
        stopPinging()
    end
end

local function startPinging()
    stopPinging()
    pingInterval = socket.setInterval(10, function()
        if ws then
            ws:send(json.encode({type = "PING"}))
            setLocalStorage({lastPingDate = os.date("!%Y-%m-%dT%H:%M:%SZ")})
        end
    end)
end

local function stopPinging()
    if pingInterval then
        socket.clearInterval(pingInterval)
        pingInterval = nil
    end
end

local function startCountdownAndPoints()
    if countdownInterval then
        socket.clearInterval(countdownInterval)
    end
    updateCountdownAndPoints()
    countdownInterval = socket.setInterval(1, updateCountdownAndPoints)
end

local function updateCountdownAndPoints()
    local localStorage = getLocalStorage()
    local lastUpdated = localStorage.lastUpdated
    if lastUpdated then
        local nextHeartbeat = os.time(os.date("!*t", lastUpdated)) + 15 * 60
        local now = os.time()
        local diff = nextHeartbeat - now

        if diff > 0 then
            local minutes = math.floor(diff / 60)
            local seconds = diff % 60
            countdown = string.format("%dm %ds", minutes, seconds)

            local maxPoints = 25
            local timeElapsed = now - os.time(os.date("!*t", lastUpdated))
            local timeElapsedMinutes = timeElapsed / 60
            local newPoints = math.min(maxPoints, (timeElapsedMinutes / 15) * maxPoints)
            newPoints = math.floor(newPoints * 100) / 100

            if math.random() < 0.1 then
                local bonus = math.random() * 2
                newPoints = math.min(maxPoints, newPoints + bonus)
                newPoints = math.floor(newPoints * 100) / 100
            end

            potentialPoints = newPoints
        else
            countdown = "Calculating..."
            potentialPoints = 25
        end
    else
        countdown = "Calculating..."
        potentialPoints = 0
    end

    setLocalStorage({potentialPoints = potentialPoints, countdown = countdown})
end

local function getUserId()
    local loginUrl = "https://ikknngrgxuxgjhplbpey.supabase.co/auth/v1/token?grant_type=password"
    local authorization = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag"
    local apikey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag"

    print("Email: ")
    local email = io.read()
    print("Password: ")
    local password = io.read()

    local requestBody = json.encode({email = email, password = password})
    local responseBody = {}

    local request, code, responseHeaders = http.request {
        url = loginUrl,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = #requestBody,
            ["Authorization"] = authorization,
            ["apikey"] = apikey
        },
        source = ltn12.source.string(requestBody),
        sink = ltn12.sink.table(responseBody)
    }

    if code ~= 200 then
        print("Error:", table.concat(responseBody))
        return
    end

    local response = json.decode(table.concat(responseBody))
    local userId = response.user.id
    print("User ID:", userId)

    local profileUrl = string.format("https://ikknngrgxuxgjhplbpey.supabase.co/rest/v1/profiles?select=personal_code&id=eq.%s", userId)
    responseBody = {}

    request, code, responseHeaders = http.request {
        url = profileUrl,
        method = "GET",
        headers = {
            ["Authorization"] = authorization,
            ["apikey"] = apikey
        },
        sink = ltn12.sink.table(responseBody)
    }

    if code ~= 200 then
        print("Error:", table.concat(responseBody))
        return
    end

    print("Profile Data:", table.concat(responseBody))
    setLocalStorage({userId = userId})
    startCountdownAndPoints()
    connectWebSocket(userId)
end

local function main()
    local localStorage = getLocalStorage()
    local userId = localStorage.userId

    if not userId then
        print("User ID not found. Would you like to:")
        print("1. Login to your account")
        print("2. Enter User ID manually")
        print("Choose an option: ")
        local option = io.read()

        if option == "1" then
            getUserId()
        elseif option == "2" then
            print("Please enter your user ID: ")
            userId = io.read()
            setLocalStorage({userId = userId})
            startCountdownAndPoints()
            connectWebSocket(userId)
        else
            print("Invalid option. Exiting...")
            os.exit(0)
        end
    else
        print("Menu:")
        print("1. Logout")
        print("2. Start Running Node")
        print("Choose an option: ")
        local option = io.read()

        if option == "1" then
            os.remove("localStorage.json")
            print("Logged out successfully.")
            os.exit(0)
        elseif option == "2" then
            startCountdownAndPoints()
            connectWebSocket(userId)
        else
            print("Invalid option. Exiting...")
            os.exit(0)
        end
    end
end

main()

