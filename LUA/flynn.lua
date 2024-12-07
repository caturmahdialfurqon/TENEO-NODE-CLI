local websocket = require('websocket')
local json = require('json')
local fs = require('fs')
local readline = require('readline')
local http = require('http')

local cl = { gr = '\x1b[32m', gb = '\x1b[4m', br = '\x1b[34m', st = '\x1b[9m', yl = '\x1b[33m', rt = '\x1b[0m' }

local socket = nil
local pingInterval
local countdownInterval
local potentialPoints = 0
local countdown = "Calculating..."
local pointsTotal = 0
local pointsToday = 0
local reconnectAttempts = 0
local maxReconnectAttempts = 5
local maxReconnectInterval = 5 * 60 * 1000 -- 5 minutes in milliseconds
local CoderMarkPrinted = false

function CoderMark()
    if not CoderMarkPrinted then
        print([[
╭━━━╮╱╱╱╱╱╱╱╱╱╱╱╱╱╭━━━┳╮
┃╭━━╯╱╱╱╱╱╱╱╱╱╱╱╱╱┃╭━━┫┃]] .. cl.gr .. [[
┃╰━━┳╮╭┳━┳━━┳━━┳━╮┃╰━━┫┃╭╮╱╭┳━╮╭━╮
┃╭━━┫┃┃┃╭┫╭╮┃╭╮┃╭╮┫╭━━┫┃┃┃╱┃┃╭╮┫╭╮╮]] .. cl.br .. [[
┃┃╱╱┃╰╯┃┃┃╰╯┃╰╯┃┃┃┃┃╱╱┃╰┫╰━╯┃┃┃┃┃┃┃
╰╯╱╱╰━━┻╯╰━╮┣━━┻╯╰┻╯╱╱╰━┻━╮╭┻╯╰┻╯╰╯]] .. cl.rt .. [[
╱╱╱╱╱╱╱╱╱╱╱┃┃╱╱╱╱╱╱╱╱╱╱╱╭━╯┃
╱╱╱╱╱╱╱╱╱╱╱╰╯╱╱╱╱╱╱╱╱╱╱╱╰━━╯
\n]] .. cl.gb .. [[Teneo Node Cli ]] .. cl.gr .. [[v1.1.0 ]] .. cl.rt .. cl.gb .. [[dev_build]] .. cl.rt .. [[
        ]])
        CoderMarkPrinted = true
    end
end

local function readFileAsync(filename)
    local file, err = fs.readFileSync(filename, 'utf8')
    if err then return {} end
    return json.decode(file)
end

local function writeFileAsync(filename, data)
    fs.writeFileSync(filename, json.encode(data))
end

local rl = readline.createInterface({
    input = io.stdin,
    output = io.stdout
})

local function getLocalStorage()
    local success, data = pcall(readFileAsync, 'localStorage.json')
    return success and data or {}
end

local function setLocalStorage(data)
    local currentData = getLocalStorage()
    local newData = {}
    for k, v in pairs(currentData) do newData[k] = v end
    for k, v in pairs(data) do newData[k] = v end
    writeFileAsync('localStorage.json', newData)
end

local function getUserIdFromFile()
    local success, data = pcall(readFileAsync, 'UserId.json')
    return success and data.userId or nil
end

local function setUserIdToFile(userId)
    writeFileAsync('UserId.json', { userId = userId })
end

local function getAccountData()
    local success, data = pcall(readFileAsync, 'DataAccount.json')
    return success and data or {}
end

local function setAccountData(email, password, access_token, refresh_token, personalCode)
    local accountData = {
        email = email,
        password = password,
        access_token = access_token,
        refresh_token = refresh_token,
        personalCode = personalCode
    }
    writeFileAsync('DataAccount.json', accountData)
end

local function getReconnectDelay(attempt)
    local baseDelay = 5000 -- 5 seconds
    local additionalDelay = attempt * 5000 -- Additional 5 seconds for each attempt
    return math.min(baseDelay + additionalDelay, maxReconnectInterval)
end

local function connectWebSocket(userId)
    if socket then return end
    local version = "v0.2"
    local url = "wss://secure.ws.teneo.pro"
    local wsUrl = url .. "/websocket?userId=" .. http.urlEncode(userId) .. "&version=" .. http.urlEncode(version)
    socket = websocket.client()

    socket:on("connect", function()
        reconnectAttempts = 0
        local connectionTime = os.date("!%Y-%m-%dT%H:%M:%SZ")
        setLocalStorage({ lastUpdated = connectionTime })
        print("WebSocket connected at", connectionTime)
        startPinging()
        startCountdownAndPoints()
    end)

    socket:on("message", function(event)
        local data = json.decode(event)
        print("Received message from WebSocket:", data)
        if data.pointsTotal and data.pointsToday then
            local lastUpdated = os.date("!%Y-%m-%dT%H:%M:%SZ")
            setLocalStorage({
                lastUpdated = lastUpdated,
                pointsTotal = data.pointsTotal,
                pointsToday = data.pointsToday,
            })
            pointsTotal = data.pointsTotal
            pointsToday = data.pointsToday
        end
    end)

    socket:on("close", function(event)
        socket = nil
        print("WebSocket disconnected")
        stopPinging()
        if not event.wasClean then
            reconnectAttempts = reconnectAttempts + 1
            local delay = getReconnectDelay(reconnectAttempts)
            if delay < maxReconnectInterval then
                timer.sleep(delay)
                reconnectWebSocket()
            else
                print("Max reconnect interval reached. Giving up.")
            end
        end
    end)

    socket:on("error", function(error)
        print("WebSocket error:", error)
    end)

    socket:connect(wsUrl)
end

local function disconnectWebSocket()
    if socket then
        socket:close()
        socket = nil
        stopPinging()
    end
end

local function startPinging()
    stopPinging()
    pingInterval = timer.setInterval(function()
        if socket and socket.readyState == websocket.OPEN then
            socket:send(json.encode({ type = "PING" }))
            setLocalStorage({ lastPingDate = os.date("!%Y-%m-%dT%H:%M:%SZ") })
        end
    end, 10000)
end

local function stopPinging()
    if pingInterval then
        timer.clearInterval(pingInterval)
        pingInterval = nil
    end
end

local function startCountdownAndPoints()
    timer.clearInterval(countdownInterval)
    updateCountdownAndPoints()
    countdownInterval = timer.setInterval(updateCountdownAndPoints, 1000)
end

local function updateCountdownAndPoints()
    local localStorage = getLocalStorage()
    local lastUpdated = localStorage.lastUpdated
    if lastUpdated then
        local nextHeartbeat = os.date("!*t", os.time(lastUpdated) + 15 * 60)
        local now = os.date("!*t")
        local diff = os.time(nextHeartbeat) - os.time(now)

        if diff > 0 then
            local minutes = math.floor(diff / 60)
            local seconds = diff % 60
            countdown = string.format("%dm %ds", minutes, seconds)

            local maxPoints = 25
            local timeElapsed = os.time(now) - os.time(lastUpdated)
            local timeElapsedMinutes = timeElapsed / 60
            local newPoints = math.min(maxPoints, (timeElapsedMinutes / 15) * maxPoints)
            newPoints = tonumber(string.format("%.2f", newPoints))

            if math.random() < 0.1 then
                local bonus = math.random() * 2
                newPoints = math.min(maxPoints, newPoints + bonus)
                newPoints = tonumber(string.format("%.2f", newPoints))
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
    setLocalStorage({ potentialPoints = potentialPoints, countdown = countdown })
end

local function getUserId()
    local loginUrl = "https://node-community-api.teneo.pro/auth/v1/token?grant_type=password"
    local authorization = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag"
    local apikey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag"

    local accountData = getAccountData()
    local email = accountData.email or rl:question("\nEmail: " .. cl.gr)
    local password = accountData.password or rl:question(cl.rt .. "Password: " .. cl.st .. cl.br .. "", function(input) return input end)

    local response, err = http.post(loginUrl, json.encode({ email = email, password = password }), {
        headers = {
            Authorization = authorization,
            apikey = apikey
        }
    })

    if response then
        local data = json.decode(response.body)
        local access_token = data.access_token
        local refresh_token = data.refresh_token
        print('Access_Token:', access_token)
        print('Refresh_Token:', refresh_token)

        local AuthUserUrl = "https://node-community-api.teneo.pro/auth/v1/user"
        local AuthResponse = http.get(AuthUserUrl, {
            headers = {
                Authorization = "Bearer " .. access_token,
                apikey = apikey
            }
        })

        local userId = json.decode(AuthResponse.body).id
        print('User ID:', userId)

        local profileUrl = "https://node-community-api.teneo.pro/rest/v1/profiles?select=personal_code&id=eq." .. userId
        local profileResponse = http.get(profileUrl, {
            headers = {
                Authorization = "Bearer " .. access_token,
                apikey = apikey
            }
        })
        local personalCode = json.decode(profileResponse.body)[1].personal_code
        print("Personal Code:" .. cl.rt, personalCode)
        setUserIdToFile(userId)
        setAccountData(email, password, access_token, refresh_token, personalCode)
        startCountdownAndPoints()
        connectWebSocket(userId)
        io.write(cl.gr .. "Data has been saved in the DataAccount.json file...\n" .. cl.rt)
        CoderMark()
    else
        print('Error:', err)
    end
end

local function reconnectWebSocket()
    local userId = getUserIdFromFile()
    if userId then
        connectWebSocket(userId)
    end
end

local function autoLogin()
    local accountData = getAccountData()
    if accountData.email and accountData.password then
        getUserId()
        print(cl.yl .. "\nAutomatic Login has been Successfully Executed..\n" .. cl.rt)
    end
end

local function main()
    local localStorageData = getLocalStorage()
    local userId = getUserIdFromFile()

    if not userId then
        rl:question("\nUser ID not found. Would you like to:\n" .. cl.gr .. "\n1. Login to your account\n2. Enter User ID manually\n" .. cl.rt .. "\nChoose an option: ", function(option)
            if option == '1' then
                getUserId()
            elseif option == '2' then
                rl:question('Please enter your user ID: ', function(inputUserId)
                    userId = inputUserId
                    setUserIdToFile(userId)
                    startCountdownAndPoints()
                    connectWebSocket(userId)
                    rl:close()
                end)
            else
                print('Invalid option. Exiting...')
                os.exit(0)
            end
        end)
    else
        rl:question("\nMenu:\n" .. cl.gr .. "\n1. Logout\n2. Start Running Node\n" .. cl.rt .. "\nChoose an option: ", function(option)
            if option == '1' then
                fs.unlink('UserId.json', function(err) if err then error(err) end end)
                fs.unlink('localStorage.json', function(err) if err then error(err) end end)
                fs.unlink('DataAccount.json', function(err) if err then error(err) end end)
                print(cl.yl .. "\nLogged out successfully.")
                os.exit(0)
            elseif option == '2' then
                os.execute("clear")
                CoderMark()
                print(cl.gr .. "Initiates a connection to the node...\n" .. cl.rt)
                startCountdownAndPoints()
                connectWebSocket(userId)
            else
                print(cl.yl .. "Invalid option. Exiting...")
                os.exit(0)
            end
        end)
    end
end

main()
timer.setInterval(autoLogin, 1800000)

