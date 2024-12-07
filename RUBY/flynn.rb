require 'websocket-client-simple'
require 'json'
require 'fileutils'
require 'io/console'
require 'net/http'
require 'uri'

cl = { gr: "\e[32m", gb: "\e[4m", br: "\e[34m", st: "\e[9m", yl: "\e[33m", rt: "\e[0m" }

socket = nil
ping_interval = nil
countdown_interval = nil
potential_points = 0
countdown = "Calculating..."
points_total = 0
points_today = 0
reconnect_attempts = 0
max_reconnect_attempts = 5
max_reconnect_interval = 5 * 60 # 5 minutes in seconds
coder_mark_printed = false

def coder_mark
  return if coder_mark_printed

  puts <<~MARK
    ╭━━━╮╱╱╱╱╱╱╱╱╱╱╱╱╱╭━━━┳╮
    ┃╭━━╯╱╱╱╱╱╱╱╱╱╱╱╱╱┃╭━━┫┃#{cl[:gr]}
    ┃╰━━┳╮╭┳━┳━━┳━━┳━╮┃╰━━┫┃╭╮╱╭┳━╮╭━╮
    ┃╭━━┫┃┃┃╭┫╭╮┃╭╮┃╭╮┫╭━━┫┃┃┃╱┃┃╭╮┫╭╮╮#{cl[:br]}
    ┃┃╱╱┃╰╯┃┃┃╰╯┃╰╯┃┃┃┃┃╱╱┃╰┫╰━╯┃┃┃┃┃┃┃
    ╰╯╱╱╰━━┻╯╰━╮┣━━┻╯╰┻╯╱╱╰━┻━╮╭┻╯╰┻╯╰╯#{cl[:rt]}
    ╱╱╱╱╱╱╱╱╱╱╱┃┃╱╱╱╱╱╱╱╱╱╱╱╭━╯┃
    ╱╱╱╱╱╱╱╱╱╱╱╰╯╱╱╱╱╱╱╱╱╱╱╱╰━━╯
    \n#{cl[:gb]}Teneo Node Cli #{cl[:gr]}v1.1.0 #{cl[:rt]}#{cl[:gb]}#{cl[:br]}dev_build#{cl[:rt]}
  MARK

  coder_mark_printed = true
end

def read_file_async(file)
  JSON.parse(File.read(file))
rescue
  {}
end

def write_file_async(file, data)
  File.write(file, JSON.pretty_generate(data))
end

def get_local_storage
  read_file_async('localStorage.json')
end

def set_local_storage(data)
  current_data = get_local_storage
  new_data = current_data.merge(data)
  write_file_async('localStorage.json', new_data)
end

def get_user_id_from_file
  read_file_async('UserId.json')['userId']
rescue
  nil
end

def set_user_id_to_file(user_id)
  write_file_async('UserId.json', { userId: user_id })
end

def get_account_data
  read_file_async('DataAccount.json')
end

def set_account_data(email, password, access_token, refresh_token, personal_code)
  account_data = {
    email: email,
    password: password,
    access_token: access_token,
    refresh_token: refresh_token,
    personal_code: personal_code
  }
  write_file_async('DataAccount.json', account_data)
end

def get_reconnect_delay(attempt)
  base_delay = 5 # 5 seconds
  additional_delay = attempt * 5 # Additional 5 seconds for each attempt
  [base_delay + additional_delay, max_reconnect_interval].min
end

def connect_websocket(user_id)
  return if socket

  version = "v0.2"
  url = "wss://secure.ws.teneo.pro"
  ws_url = "#{url}/websocket?userId=#{URI.encode(user_id)}&version=#{URI.encode(version)}"
  socket = WebSocket::Client::Simple.connect(ws_url)

  socket.on :open do
    reconnect_attempts = 0
    connection_time = Time.now.iso8601
    set_local_storage(lastUpdated: connection_time)
    puts "WebSocket connected at #{connection_time}"
    start_pinging
    start_countdown_and_points
  end

  socket.on :message do |event|
    data = JSON.parse(event.data)
    puts "Received message from WebSocket: #{data}"
    if data['pointsTotal'] && data['pointsToday']
      last_updated = Time.now.iso8601
      set_local_storage(lastUpdated: last_updated, pointsTotal: data['pointsTotal'], pointsToday: data['pointsToday'])
      points_total = data['pointsTotal']
      points_today = data['pointsToday']
    end
  end

  socket.on :close do |event|
    socket = nil
    puts "WebSocket disconnected"
    stop_pinging
    unless event.was_clean
      reconnect_attempts += 1
      delay = get_reconnect_delay(reconnect_attempts)
      if delay < max_reconnect_interval
        sleep(delay)
        reconnect_websocket
      else
        puts "Max reconnect interval reached. Giving up."
      end
    end
  end

  socket.on :error do |error|
    puts "WebSocket error: #{error}"
  end
end

def disconnect_websocket
  if socket
    socket.close
    socket = nil
    stop_pinging
  end
end

def start_pinging
  stop_pinging
  ping_interval = Thread.new do
    loop do
      if socket && socket.ready_state == WebSocket::Client::Simple::OPEN
        socket.send(JSON.generate({ type: "PING" }))
        set_local_storage(lastPingDate: Time.now.iso8601)
      end
      sleep(10)
    end
  end
end

def stop_pinging
  if ping_interval
    ping_interval.kill
    ping_interval = nil
  end
end

Signal.trap("INT") do
  puts 'Received SIGINT. Stopping pinging...'
  stop_pinging
  disconnect_websocket
  exit(0)
end

def start_countdown_and_points
  countdown_interval = Thread.new do
    loop do
      update_countdown_and_points
      sleep(1)
    end
  end
end

def update_countdown_and_points
  last_updated = get_local_storage['lastUpdated']
  if last_updated
    next_heartbeat = Time.parse(last_updated) + 15 * 60
    now = Time.now
    diff = next_heartbeat - now

    if diff > 0
      minutes = (diff / 60).to_i
      seconds = (diff % 60).to_i
      countdown = "#{minutes}m #{seconds}s"

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

      potential_points = new_points
    else
      countdown = "Calculating..."
      potential_points = 25
    end
  else
    countdown = "Calculating..."
    potential_points = 0
  end
  set_local_storage(potentialPoints: potential_points, countdown: countdown)
end

def get_user_id
  login_url = "https://node-community-api.teneo.pro/auth/v1/token?grant_type=password"
  authorization = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag"
  apikey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag"

  account_data = get_account_data
  email = account_data['email'] || (print "\nEmail: #{cl[:gr]}"; gets.chomp)
  password = account_data['password'] || (print "#{cl[:rt]}Password: #{cl[:st]}#{cl[:br]}"; gets.chomp)

  begin
    uri = URI.parse(login_url)
    response = Net::HTTP.post_form(uri, { email: email, password: password }, { 'Authorization' => authorization, 'apikey' => apikey })
    data = JSON.parse(response.body)

    access_token = data['access_token']
    refresh_token = data['refresh_token']
    puts "Access_Token: #{access_token}"
    puts "Refresh_Token: #{refresh_token}"

    auth_user_url = "https://node-community-api.teneo.pro/auth/v1/user"
    uri = URI.parse(auth_user_url)
    auth_response = Net::HTTP.get_response(uri, { 'Authorization' => "Bearer #{access_token}", 'apikey' => apikey })
    user_id = JSON.parse(auth_response.body)['id']
    puts "User ID: #{user_id}"

    profile_url = "https://node-community-api.teneo.pro/rest/v1/profiles?select=personal_code&id=eq.#{user_id}"
    uri = URI.parse(profile_url)
    profile_response = Net::HTTP.get_response(uri, { 'Authorization' => "Bearer #{access_token}", 'apikey' => apikey })
    personal_code = JSON.parse(profile_response.body)[0]['personal_code']
    puts "Personal Code: #{cl[:rt]}#{personal_code}"
    set_user_id_to_file(user_id)
    set_account_data(email, password, access_token, refresh_token, personal_code)
    start_countdown_and_points
    connect_websocket(user_id)
    system("clear")
    puts "#{cl[:gr]}Data has been saved in the DataAccount.json file...\n#{cl[:rt]}"
    coder_mark
  rescue => error
    puts "Error: #{error.message}"
  end
end

def reconnect_websocket
  user_id = get_user_id_from_file
  connect_websocket(user_id) if user_id
end

def auto_login
  account_data = get_account_data
  if account_data['email'] && account_data['password']
    get_user_id
    puts "#{cl[:yl]}\nAutomatic Login has been Successfully Executed..\n#{cl[:rt]}"
  end
end

def main
  local_storage_data = get_local_storage
  user_id = get_user_id_from_file

  if user_id.nil?
    print "\nUser ID not found. Would you like to:\n#{cl[:gr]}\n1. Login to your account\n2. Enter User ID manually\n#{cl[:rt]}\nChoose an option: "
    option = gets.chomp
    case option
    when '1'
      get_user_id
    when '2'
      print 'Please enter your user ID: '
      user_id = gets.chomp
      set_user_id_to_file(user_id)
      start_countdown_and_points
      connect_websocket(user_id)
    else
      puts 'Invalid option. Exiting...'
      exit(0)
    end
  else
    print "\nMenu:\n#{cl[:gr]}\n1. Logout\n2. Start Running Node\n#{cl[:rt]}\nChoose an option: "
    option = gets.chomp
    case option
    when '1'
      FileUtils.rm_f('UserId.json')
      FileUtils.rm_f('localStorage.json')
      FileUtils.rm_f('DataAccount.json')
      puts "#{cl[:yl]}\nLogged out successfully."
      exit(0)
    when '2'
      system("clear")
      coder_mark
      puts "#{cl[:gr]}Initiates a connection to the node...\n#{cl[:rt]}"
      start_countdown_and_points
      connect_websocket(user_id)
    else
      puts "#{cl[:yl]}Invalid option. Exiting..."
      exit(0)
    end
  end
end

main
Thread.new { loop { auto_login; sleep(1800) } }

