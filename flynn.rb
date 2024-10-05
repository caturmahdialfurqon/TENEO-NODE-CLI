require 'websocket-client-simple'
require 'json'
require 'fileutils'
require 'readline'
require 'httparty'

$socket = nil
$ping_interval = nil
$countdown_interval = nil
$potential_points = 0
$countdown = "Calculating..."
$points_total = 0
$points_today = 0

def get_local_storage
  begin
    data = File.read('localStorage.json')
    JSON.parse(data)
  rescue
    {}
  end
end

def set_local_storage(data)
  current_data = get_local_storage
  new_data = current_data.merge(data)
  File.write('localStorage.json', JSON.generate(new_data))
end

def connect_websocket(user_id)
  return if $socket
  version = "v0.2"
  url = "wss://secure.ws.teneo.pro"
  ws_url = "#{url}/websocket?userId=#{URI.encode_www_form_component(user_id)}&version=#{URI.encode_www_form_component(version)}"
  $socket = WebSocket::Client::Simple.connect(ws_url)

  $socket.on :open do
    connection_time = Time.now.iso8601
    set_local_storage({ 'lastUpdated' => connection_time })
    puts "WebSocket connected at #{connection_time}"
    start_pinging
    start_countdown_and_points
  end

  $socket.on :message do |event|
    data = JSON.parse(event.data)
    puts "Received message from WebSocket: #{data}"
    if data['pointsTotal'] && data['pointsToday']
      last_updated = Time.now.iso8601
      set_local_storage({
        'lastUpdated' => last_updated,
        'pointsTotal' => data['pointsTotal'],
        'pointsToday' => data['pointsToday']
      })
      $points_total = data['pointsTotal']
      $points_today = data['pointsToday']
    end
  end

  $socket.on :close do
    $socket = nil
    puts "WebSocket disconnected"
    stop_pinging
  end

  $socket.on :error do |error|
    puts "WebSocket error: #{error}"
  end
end

def disconnect_websocket
  if $socket
    $socket.close
    $socket = nil
    stop_pinging
  end
end

def start_pinging
  stop_pinging
  $ping_interval = Thread.new do
    loop do
      if $socket && $socket.open?
        $socket.send(JSON.generate({ type: "PING" }))
        set_local_storage({ 'lastPingDate' => Time.now.iso8601 })
      end
      sleep 10
    end
  end
end

def stop_pinging
  $ping_interval.kill if $ping_interval
  $ping_interval = nil
end

trap('INT') do
  puts 'Received SIGINT. Stopping pinging...'
  stop_pinging
  disconnect_websocket
  exit 0
end

def start_countdown_and_points
  $countdown_interval&.kill
  update_countdown_and_points
  $countdown_interval = Thread.new do
    loop do
      update_countdown_and_points
      sleep 1
    end
  end
end

def update_countdown_and_points
  local_storage = get_local_storage
  last_updated = local_storage['lastUpdated']
  if last_updated
    next_heartbeat = Time.parse(last_updated) + (15 * 60)
    now = Time.now
    diff = next_heartbeat - now

    if diff > 0
      minutes = (diff / 60).to_i
      seconds = (diff % 60).to_i
      $countdown = "#{minutes}m #{seconds}s"

      max_points = 25
      time_elapsed = now - Time.parse(last_updated)
      time_elapsed_minutes = time_elapsed / 60
      new_points = [max_points, (time_elapsed_minutes / 15) * max_points].min
      new_points = new_points.round(2)

      if rand < 0.1
        bonus = rand * 2
        new_points = [max_points, new_points + bonus].min
        new_points = new_points.round(2)
      end

      $potential_points = new_points
    else
      $countdown = "Calculating..."
      $potential_points = 25
    end
  else
    $countdown = "Calculating..."
    $potential_points = 0
  end

  set_local_storage({ 'potentialPoints' => $potential_points, 'countdown' => $countdown })
end

def get_user_id
  login_url = "https://ikknngrgxuxgjhplbpey.supabase.co/auth/v1/token?grant_type=password"
  authorization = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag"
  apikey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag"

  email = Readline.readline('Email: ', true)
  password = Readline.readline('Password: ', true)

  begin
    response = HTTParty.post(login_url, 
      body: { email: email, password: password }.to_json,
      headers: {
        'Authorization' => authorization,
        'apikey' => apikey,
        'Content-Type' => 'application/json'
      }
    )

    user_id = response['user']['id']
    puts "User ID: #{user_id}"

    profile_url = "https://ikknngrgxuxgjhplbpey.supabase.co/rest/v1/profiles?select=personal_code&id=eq.#{user_id}"
    profile_response = HTTParty.get(profile_url,
      headers: {
        'Authorization' => authorization,
        'apikey' => apikey
      }
    )

    puts "Profile Data: #{profile_response.body}"
    set_local_storage({ 'userId' => user_id })
    start_countdown_and_points
    connect_websocket(user_id)
  rescue => e
    puts "Error: #{e.message}"
  end
end

def main
  local_storage_data = get_local_storage
  user_id = local_storage_data['userId']

  if !user_id
    user_id = Readline.readline('Please enter your user ID: ', true)
    set_local_storage({ 'userId' => user_id })
    start_countdown_and_points
    connect_websocket(user_id)
  else
    option = Readline.readline("Menu:\n1. Logout\n2. Start Running Node\n3. Get User ID\nChoose an option: ", true)
    case option
    when '1'
      set_local_storage({})
      puts 'Logged out successfully.'
      exit 0
    when '2'
      start_countdown_and_points
      connect_websocket(user_id)
    when '3'
      get_user_id
    else
      puts 'Invalid option. Exiting...'
      exit 0
    end
  end
end

main

