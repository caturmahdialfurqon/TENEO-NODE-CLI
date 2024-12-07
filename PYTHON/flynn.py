import json
import asyncio
import websockets
import os
import random
import time
import aiofiles

cl = {'gr': '\x1b[32m', 'gb': '\x1b[4m', 'br': '\x1b[34m', 'st': '\x1b[9m', 'yl': '\x1b[33m', 'rt': '\x1b[0m'}

socket = None
ping_interval = None
countdown_interval = None
potential_points = 0
countdown = "Calculating..."
points_total = 0
points_today = 0
reconnect_attempts = 0
max_reconnect_attempts = 5
max_reconnect_interval = 5 * 60  # 5 minutes in seconds
CoderMarkPrinted = False

def CoderMark():
    global CoderMarkPrinted
    if not CoderMarkPrinted:
        print(f"""
╭━━━╮╱╱╱╱╱╱╱╱╱╱╱╱╱╭━━━┳╮
┃╭━━╯╱╱╱╱╱╱╱╱╱╱╱╱╱┃╭━━┫┃{cl['gr']}
┃╰━━┳╮╭┳━┳━━┳━━┳━╮┃╰━━┫┃╭╮╱╭┳━╮╭━╮
┃╭━━┫┃┃┃╭┫╭╮┃╭╮┃╭╮┫╭━━┫┃┃┃╱┃┃╭╮┫╭╮╮{cl['br']}
┃┃╱╱┃╰╯┃┃┃╰╯┃╰╯┃┃┃┃┃╱╱┃╰┫╰━╯┃┃┃┃┃┃┃
╰╯╱╱╰━━┻╯╰━╮┣━━┻╯╰┻╯╱╱╰━┻━╮╭┻╯╰┻╯╰╯{cl['rt']}
╱╱╱╱╱╱╱╱╱╱╱┃┃╱╱╱╱╱╱╱╱╱╱╱╭━╯┃
╱╱╱╱╱╱╱╱╱╱╱╰╯╱╱╱╱╱╱╱╱╱╱╱╰━━╯
\n{cl['gb']}Teneo Node Cli {cl['gr']}v1.1.0 {cl['rt']}{cl['gb']}{cl['br']}dev_build{cl['rt']}
        """)
        CoderMarkPrinted = True

async def read_file_async(file_path):
    try:
        async with aiofiles.open(file_path, 'r') as f:
            contents = await f.read()
            return json.loads(contents)
    except Exception:
        return {}

async def write_file_async(file_path, data):
    async with aiofiles.open(file_path, 'w') as f:
        await f.write(json.dumps(data))

async def get_local_storage():
    return await read_file_async('localStorage.json')

async def set_local_storage(data):
    current_data = await get_local_storage()
    new_data = {**current_data, **data}
    await write_file_async('localStorage.json', new_data)

async def get_user_id_from_file():
    try:
        data = await read_file_async('UserId.json')
        return data.get('userId')
    except Exception:
        return None

async def set_user_id_to_file(user_id):
    await write_file_async('UserId.json', {'userId': user_id})

async def get_account_data():
    return await read_file_async('DataAccount.json')

async def set_account_data(email, password, access_token, refresh_token, personal_code):
    account_data = {
        'email': email,
        'password': password,
        'access_token': access_token,
        'refresh_token': refresh_token,
        'personalCode': personal_code
    }
    await write_file_async('DataAccount.json', account_data)

def get_reconnect_delay(attempt):
    base_delay = 5  # 5 seconds
    additional_delay = attempt * 5  # Additional 5 seconds for each attempt
    return min(base_delay + additional_delay, max_reconnect_interval)

async def connect_websocket(user_id):
    global socket, reconnect_attempts
    if socket:
        return
    version = "v0.2"
    url = "wss://secure.ws.teneo.pro"
    ws_url = f"{url}/websocket?userId={user_id}&version={version}"
    socket = await websockets.connect(ws_url)

    async def on_open():
        nonlocal reconnect_attempts
        reconnect_attempts = 0
        connection_time = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
        await set_local_storage({'lastUpdated': connection_time})
        print("WebSocket connected at", connection_time)
        start_pinging()
        start_countdown_and_points()

    async def on_message():
        async for message in socket:
            data = json.loads(message)
            print("Received message from WebSocket:", data)
            if 'pointsTotal' in data and 'pointsToday' in data:
                last_updated = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
                await set_local_storage({
                    'lastUpdated': last_updated,
                    'pointsTotal': data['pointsTotal'],
                    'pointsToday': data['pointsToday'],
                })
                global points_total, points_today
                points_total = data['pointsTotal']
                points_today = data['pointsToday']

    async def on_close():
        global socket
        socket = None
        print("WebSocket disconnected")
        stop_pinging()
        if reconnect_attempts < max_reconnect_attempts:
            reconnect_attempts += 1
            delay = get_reconnect_delay(reconnect_attempts)
            await asyncio.sleep(delay)
            await reconnect_websocket()

    async def on_error(error):
        print("WebSocket error:", error)

    await on_open()
    await on_message()
    await on_close()

def disconnect_websocket():
    global socket
    if socket:
        asyncio.create_task(socket.close())
        socket = None
        stop_pinging()

def start_pinging():
    stop_pinging()
    global ping_interval
    ping_interval = asyncio.get_event_loop().call_later(10, ping)

async def ping():
    global socket
    if socket and socket.open:
        await socket.send(json.dumps({'type': 'PING'}))
        await set_local_storage({'lastPingDate': time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())})
    start_pinging()

def stop_pinging():
    global ping_interval
    if ping_interval:
        ping_interval.cancel()
        ping_interval = None

async def update_countdown_and_points():
    global potential_points, countdown
    local_storage = await get_local_storage()
    last_updated = local_storage.get('lastUpdated')
    if last_updated:
        next_heartbeat = time.strptime(last_updated, "%Y-%m-%dT%H:%M:%S")
        next_heartbeat = time.mktime(next_heartbeat) + 15 * 60  # 15 minutes
        now = time.time()
        diff = next_heartbeat - now

        if diff > 0:
            minutes = diff // 60
            seconds = diff % 60
            countdown = f"{int(minutes)}m {int(seconds)}s"

            max_points = 25
            time_elapsed = now - time.mktime(time.strptime(last_updated, "%Y-%m-%dT%H:%M:%S"))
            time_elapsed_minutes = time_elapsed / 60
            new_points = min(max_points, (time_elapsed_minutes / 15) * max_points)
            new_points = round(new_points, 2)

            if random.random() < 0.1:
                bonus = random.uniform(0, 2)
                new_points = min(max_points, new_points + bonus)
                new_points = round(new_points, 2)

            potential_points = new_points
        else:
            countdown = "Calculating..."
            potential_points = 25
    else:
        countdown = "Calculating..."
        potential_points = 0

    await set_local_storage({'potentialPoints': potential_points, 'countdown': countdown})

async def get_user_id():
    login_url = "https://node-community-api.teneo.pro/auth/v1/token?grant_type=password"
    authorization = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag"
    apikey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag"

    account_data = await get_account_data()
    email = account_data.get('email') or input(f"\nEmail: {cl['gr']}")
    password = account_data.get('password') or input(f"{cl['rt']}Password: {cl['st']}{cl['br']}")

    try:
        async with aiohttp.ClientSession() as session:
            async with session.post(login_url, json={'email': email, 'password': password}, headers={'Authorization': authorization, 'apikey': apikey}) as response:
                response_data = await response.json()
                access_token = response_data['access_token']
                refresh_token = response_data['refresh_token']
                print('Access_Token:', access_token)
                print('Refresh_Token:', refresh_token)

                auth_user_url = "https://node-community-api.teneo.pro/auth/v1/user"
                async with session.get(auth_user_url, headers={'Authorization': f'Bearer {access_token}', 'apikey': apikey}) as auth_response:
                    auth_response_data = await auth_response.json()
                    user_id = auth_response_data['id']
                    print('User ID:', user_id)

                    profile_url = f"https://node-community-api.teneo.pro/rest/v1/profiles?select=personal_code&id=eq.{user_id}"
                    async with session.get(profile_url, headers={'Authorization': f'Bearer {access_token}', 'apikey': apikey}) as profile_response:
                        profile_response_data = await profile_response.json()
                        personal_code = profile_response_data[0].get('personal_code')
                        print(f"Personal Code: {cl['rt']}", personal_code)
                        await set_user_id_to_file(user_id)
                        await set_account_data(email, password, access_token, refresh_token, personal_code)
                        await start_countdown_and_points()
                        await connect_websocket(user_id)
                        os.system('clear')
                        print(cl['gr'] + "Data has been saved in the DataAccount.json file...\n" + cl['rt'])
                        CoderMark()
    except Exception as error:
        print('Error:', error)
    finally:
        await asyncio.sleep(0)

async def reconnect_websocket():
    user_id = await get_user_id_from_file()
    if user_id:
        await connect_websocket(user_id)

async def auto_login():
    account_data = await get_account_data()
    if account_data.get('email') and account_data.get('password'):
        await get_user_id()
        print(cl['yl'] + "\nAutomatic Login has been Successfully Executed..\n" + cl['rt'])

async def main():
    local_storage_data = await get_local_storage()
    user_id = await get_user_id_from_file()

    if not user_id:
        option = input(f"\nUser ID not found. Would you like to:\n{cl['gr']}\n1. Login to your account\n2. Enter User ID manually\n{cl['rt']}\nChoose an option: ")
        if option == '1':
            await get_user_id()
        elif option == '2':
            input_user_id = input('Please enter your user ID: ')
            await set_user_id_to_file(input_user_id)
            await start_countdown_and_points()
            await connect_websocket(input_user_id)
        else:
            print('Invalid option. Exiting...')
            exit(0)
    else:
        option = input(f"\nMenu:\n{cl['gr']}\n1. Logout\n2. Start Running Node\n{cl['rt']}\nChoose an option: ")
        if option == '1':
            os.remove('UserId.json')
            os.remove('localStorage.json')
            os.remove('DataAccount.json')
            print(cl['yl'] + "\nLogged out successfully.")
            exit(0)
        elif option == '2':
            os.system('clear')
            CoderMark()
            print(cl['gr'] + "Initiates a connection to the node...\n" + cl['rt'])
            await start_countdown_and_points()
            await connect_websocket(user_id)
        else:
            print(cl['yl'] + "Invalid option. Exiting...")
            exit(0)

asyncio.run(main())
asyncio.get_event_loop().call_later(1800, auto_login)

