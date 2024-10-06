import asyncio
import json
import random
import websockets
import aiofiles
import aiohttp
from datetime import datetime, timedelta

socket = None
ping_task = None
countdown_task = None
potential_points = 0
countdown = "Calculating..."
points_total = 0
points_today = 0

async def get_local_storage():
    try:
        async with aiofiles.open('localStorage.json', 'r') as f:
            data = await f.read()
        return json.loads(data)
    except:
        return {}

async def set_local_storage(data):
    current_data = await get_local_storage()
    new_data = {**current_data, **data}
    async with aiofiles.open('localStorage.json', 'w') as f:
        await f.write(json.dumps(new_data))

async def connect_websocket(user_id):
    global socket, ping_task, countdown_task
    if socket:
        return
    version = "v0.2"
    url = "wss://secure.ws.teneo.pro"
    ws_url = f"{url}/websocket?userId={user_id}&version={version}"
    
    async def on_message(websocket, path):
        global points_total, points_today
        async for message in websocket:
            data = json.loads(message)
            print("Received message from WebSocket:", data)
            if 'pointsTotal' in data and 'pointsToday' in data:
                last_updated = datetime.now().isoformat()
                await set_local_storage({
                    'lastUpdated': last_updated,
                    'pointsTotal': data['pointsTotal'],
                    'pointsToday': data['pointsToday'],
                })
                points_total = data['pointsTotal']
                points_today = data['pointsToday']

    socket = await websockets.connect(ws_url)
    connection_time = datetime.now().isoformat()
    await set_local_storage({'lastUpdated': connection_time})
    print("WebSocket connected at", connection_time)
    
    ping_task = asyncio.create_task(start_pinging())
    countdown_task = asyncio.create_task(start_countdown_and_points())

async def disconnect_websocket():
    global socket, ping_task, countdown_task
    if socket:
        await socket.close()
        socket = None
    if ping_task:
        ping_task.cancel()
    if countdown_task:
        countdown_task.cancel()

async def start_pinging():
    while True:
        if socket and socket.open:
            await socket.send(json.dumps({"type": "PING"}))
            await set_local_storage({'lastPingDate': datetime.now().isoformat()})
        await asyncio.sleep(10)

async def start_countdown_and_points():
    while True:
        await update_countdown_and_points()
        await asyncio.sleep(1)

async def update_countdown_and_points():
    global countdown, potential_points
    local_storage = await get_local_storage()
    last_updated = local_storage.get('lastUpdated')
    if last_updated:
        next_heartbeat = datetime.fromisoformat(last_updated) + timedelta(minutes=15)
        now = datetime.now()
        diff = (next_heartbeat - now).total_seconds()

        if diff > 0:
            minutes, seconds = divmod(int(diff), 60)
            countdown = f"{minutes}m {seconds}s"

            max_points = 25
            time_elapsed = (now - datetime.fromisoformat(last_updated)).total_seconds() / 60
            new_points = min(max_points, (time_elapsed / 15) * max_points)
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
    login_url = "https://ikknngrgxuxgjhplbpey.supabase.co/auth/v1/token?grant_type=password"
    authorization = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag"
    apikey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag"

    email = input('Email: ')
    password = input('Password: ')

    async with aiohttp.ClientSession() as session:
        async with session.post(login_url, json={
            'email': email,
            'password': password
        }, headers={
            'Authorization': authorization,
            'apikey': apikey
        }) as response:
            data = await response.json()
            user_id = data['user']['id']
            print('User ID:', user_id)

            profile_url = f"https://ikknngrgxuxgjhplbpey.supabase.co/rest/v1/profiles?select=personal_code&id=eq.{user_id}"
            async with session.get(profile_url, headers={
                'Authorization': authorization,
                'apikey': apikey
            }) as profile_response:
                profile_data = await profile_response.json()
                print('Profile Data:', profile_data)

    await set_local_storage({'userId': user_id})
    await start_countdown_and_points()
    await connect_websocket(user_id)

async def main():
    local_storage_data = await get_local_storage()
    user_id = local_storage_data.get('userId')

    if not user_id:
        option = input('User ID not found. Would you like to:\n1. Login to your account\n2. Enter User ID manually\nChoose an option: ')
        if option == '1':
            await get_user_id()
        elif option == '2':
            user_id = input('Please enter your user ID: ')
            await set_local_storage({'userId': user_id})
            await start_countdown_and_points()
            await connect_websocket(user_id)
        else:
            print('Invalid option. Exiting...')
            return
    else:
        option = input('Menu:\n1. Logout\n2. Start Running Node\nChoose an option: ')
        if option == '1':
            import os
            os.remove('localStorage.json')
            print('Logged out successfully.')
        elif option == '2':
            await start_countdown_and_points()
            await connect_websocket(user_id)
        else:
            print('Invalid option. Exiting...')

if __name__ == "__main__":
    asyncio.run(main())

