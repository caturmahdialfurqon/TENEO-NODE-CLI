import json
import asyncio
import websockets
import os
import aiofiles
import random
import requests
import sys

socket = None
ping_interval = None
countdown_interval = None
potential_points = 0
countdown = "Calculating..."
points_total = 0
points_today = 0

async def read_file_async(file_path):
    try:
        async with aiofiles.open(file_path, 'r') as f:
            return json.loads(await f.read())
    except (FileNotFoundError, json.JSONDecodeError):
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
    data = await read_file_async('UserId.json')
    return data.get('userId')

async def set_user_id_to_file(user_id):
    await write_file_async('UserId.json', {'userId': user_id})

async def get_account_data():
    return await read_file_async('DataAccount.json')

async def set_account_data(email, password):
    account_data = {'email': email, 'password': password}
    await write_file_async('DataAccount.json', account_data)

async def connect_websocket(user_id):
    global socket
    if socket:
        return
    version = "v0.2"
    url = "wss://secure.ws.teneo.pro"
    ws_url = f"{url}/websocket?userId={user_id}&version={version}"
    socket = await websockets.connect(ws_url)

    async def on_open():
        connection_time = asyncio.get_event_loop().time()
        await set_local_storage({'lastUpdated': connection_time})
        print("WebSocket connected at", connection_time)
        start_pinging()
        await start_countdown_and_points()

    async def on_message():
        async for message in socket:
            data = json.loads(message)
            print("Received message from WebSocket:", data)
            if 'pointsTotal' in data and 'pointsToday' in data:
                last_updated = asyncio.get_event_loop().time()
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
        await reconnect_websocket(user_id)

    async def on_error(error):
        print("WebSocket error:", error)

    await on_open()
    try:
        await on_message()
    except Exception as e:
        await on_error(e)
    finally:
        await on_close()

async def reconnect_websocket(user_id):
    print("Attempting to reconnect...")
    await asyncio.sleep(5)  # Wait before reconnecting
    await connect_websocket(user_id)

def disconnect_websocket():
    global socket
    if socket:
        asyncio.create_task(socket.close())
        socket = None
        stop_pinging()

def start_pinging():
    stop_pinging()
    global ping_interval
    ping_interval = asyncio.get_event_loop().call_later(10, lambda: asyncio.create_task(ping()))

def stop_pinging():
    global ping_interval
    if ping_interval:
        ping_interval.cancel()
        ping_interval = None

async def ping():
    if socket and socket.open:
        await socket.send(json.dumps({'type': 'PING'}))
        await set_local_storage({'lastPingDate': asyncio.get_event_loop().time()})
    start_pinging()

async def update_countdown_and_points():
    global potential_points, countdown
    local_storage = await get_local_storage()
    last_updated = local_storage.get('lastUpdated')
    if last_updated:
        next_heartbeat = last_updated + 15 * 60
        now = asyncio.get_event_loop().time()
        diff = next_heartbeat - now

        if diff > 0:
            minutes = int(diff // 60)
            seconds = int(diff % 60)
            countdown = f"{minutes}m {seconds}s"

            max_points = 25
            time_elapsed = now - last_updated
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

async def start_countdown_and_points():
    global countdown_interval
    if countdown_interval:
        countdown_interval.cancel()
    await update_countdown_and_points()
    countdown_interval = asyncio.get_event_loop().call_later(1, lambda: asyncio.create_task(update_countdown_and_points()))

async def get_user_id():
    login_url = "https://ikknngrgxuxgjhplbpey.supabase.co/auth/v1/token?grant_type=password"
    authorization = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag"
    apikey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag"

    account_data = await get_account_data()
    email = account_data.get('email') or input('Email: ')
    password = account_data.get('password') or input('Password: ')

    try:
        response = requests.post(login_url, json={'email': email, 'password': password}, headers={
            'Authorization': authorization,
            'apikey': apikey
        })
        response.raise_for_status()
        user_id = response.json()['user']['id']
        print('User ID:', user_id)

        profile_url = f"https://ikknngrgxuxgjhplbpey.supabase.co/rest/v1/profiles?select=personal_code&id=eq.{user_id}"
        profile_response = requests.get(profile_url, headers={
            'Authorization': authorization,
            'apikey': apikey
        })
        print('Profile Data:', profile_response.json())
        await set_user_id_to_file(user_id)
        await set_account_data(email, password)
        await start_countdown_and_points()
        await connect_websocket(user_id)
    except requests.RequestException as error:
        print('Error:', error)
    finally:
        asyncio.get_event_loop().stop()

async def auto_login():
    account_data = await get_account_data()
    if account_data.get('email') and account_data.get('password'):
        await get_user_id()

async def main():
    local_storage_data = await get_local_storage()
    user_id = await get_user_id_from_file()

    if not user_id:
        option = input('User ID not found. Would you like to:\n1. Login to your account\n2. Enter User ID manually\nChoose an option: ')
        if option == '1':
            await get_user_id()
        elif option == '2':
            input_user_id = input('Please enter your user ID: ')
            await set_user_id_to_file(input_user_id)
            await start_countdown_and_points()
            await connect_websocket(input_user_id)
        else:
            print('Invalid option. Exiting...')
            sys.exit(0)
    else:
        option = input('Menu:\n1. Logout\n2. Start Running Node\nChoose an option: ')
        if option == '1':
            os.remove('UserId.json')
            os.remove('localStorage.json')
            os.remove('DataAccount.json')
            print('Logged out successfully.')
            sys.exit(0)
        elif option == '2':
            await start_countdown_and_points()
            await connect_websocket(user_id)
        else:
            print('Invalid option. Exiting...')
            sys.exit(0)

if __name__ == "__main__":
    asyncio.run(main())
    asyncio.get_event_loop().call_later(3600, auto_login)

