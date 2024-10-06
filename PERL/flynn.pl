use strict;
use warnings;
use IO::Socket::SSL;
use JSON;
use Time::HiRes qw(time sleep);
use POSIX qw(strftime);
use LWP::UserAgent;
use HTTP::Request::Common;
use Term::ReadLine;
use Fcntl qw(:flock);

my $socket;
my $ping_interval;
my $countdown_interval;
my $potential_points = 0;
my $countdown = "Calculating...";
my $points_total = 0;
my $points_today = 0;

my $term = Term::ReadLine->new('Console');

sub get_local_storage {
    my $data = {};
    if (open my $fh, '<', 'localStorage.json') {
        local $/;
        my $json = <$fh>;
        close $fh;
        $data = eval { decode_json($json) } || {};
    }
    return $data;
}

sub set_local_storage {
    my ($new_data) = @_;
    my $current_data = get_local_storage();
    my $merged_data = { %$current_data, %$new_data };
    open my $fh, '>', 'localStorage.json' or die "Cannot open localStorage.json: $!";
    flock($fh, LOCK_EX) or die "Cannot lock localStorage.json: $!";
    print $fh encode_json($merged_data);
    close $fh;
}

sub connect_websocket {
    my ($user_id) = @_;
    return if $socket;

    my $version = "v0.2";
    my $url = "wss://secure.ws.teneo.pro";
    my $ws_url = "$url/websocket?userId=$user_id&version=$version";

    $socket = IO::Socket::SSL->new(
        PeerAddr => 'secure.ws.teneo.pro',
        PeerPort => 443,
        SSL_verify_mode => 0,
    ) or die "Cannot connect to WebSocket server: $!";

    print $socket "GET $ws_url HTTP/1.1\r\n";
    print $socket "Host: secure.ws.teneo.pro\r\n";
    print $socket "Upgrade: websocket\r\n";
    print $socket "Connection: Upgrade\r\n";
    print $socket "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n";
    print $socket "Sec-WebSocket-Version: 13\r\n\r\n";

    my $connection_time = strftime("%Y-%m-%dT%H:%M:%S", localtime);
    set_local_storage({ lastUpdated => $connection_time });
    print "WebSocket connected at $connection_time\n";

    start_pinging();
    start_countdown_and_points();

    while (my $line = <$socket>) {
        chomp $line;
        if ($line =~ /^{/) {
            my $data = decode_json($line);
            print "Received message from WebSocket: ", encode_json($data), "\n";
            if (defined $data->{pointsTotal} && defined $data->{pointsToday}) {
                my $last_updated = strftime("%Y-%m-%dT%H:%M:%S", localtime);
                set_local_storage({
                    lastUpdated => $last_updated,
                    pointsTotal => $data->{pointsTotal},
                    pointsToday => $data->{pointsToday},
                });
                $points_total = $data->{pointsTotal};
                $points_today = $data->{pointsToday};
            }
        }
    }

    $socket = undef;
    print "WebSocket disconnected\n";
    stop_pinging();
}

sub disconnect_websocket {
    if ($socket) {
        close $socket;
        $socket = undef;
        stop_pinging();
    }
}

sub start_pinging {
    stop_pinging();
    $ping_interval = Time::HiRes::timer_every(10, sub {
        if ($socket) {
            print $socket encode_json({ type => "PING" });
            set_local_storage({ lastPingDate => strftime("%Y-%m-%dT%H:%M:%S", localtime) });
        }
    });
}

sub stop_pinging {
    if ($ping_interval) {
        Time::HiRes::timer_cancel($ping_interval);
        $ping_interval = undef;
    }
}

$SIG{INT} = sub {
    print "Received SIGINT. Stopping pinging...\n";
    stop_pinging();
    disconnect_websocket();
    exit 0;
};

sub start_countdown_and_points {
    Time::HiRes::timer_cancel($countdown_interval) if $countdown_interval;
    update_countdown_and_points();
    $countdown_interval = Time::HiRes::timer_every(1, \&update_countdown_and_points);
}

sub update_countdown_and_points {
    my $local_storage = get_local_storage();
    my $last_updated = $local_storage->{lastUpdated};
    if ($last_updated) {
        my $next_heartbeat = Time::Piece->strptime($last_updated, "%Y-%m-%dT%H:%M:%S")->add(minutes => 15);
        my $now = Time::Piece->new;
        my $diff = $next_heartbeat - $now;

        if ($diff > 0) {
            my $minutes = int($diff / 60);
            my $seconds = $diff % 60;
            $countdown = sprintf("%dm %ds", $minutes, $seconds);

            my $max_points = 25;
            my $time_elapsed = $now - Time::Piece->strptime($last_updated, "%Y-%m-%dT%H:%M:%S");
            my $time_elapsed_minutes = $time_elapsed / 60;
            my $new_points = ($time_elapsed_minutes / 15) * $max_points;
            $new_points = $max_points if $new_points > $max_points;
            $new_points = sprintf("%.2f", $new_points);

            if (rand() < 0.1) {
                my $bonus = rand() * 2;
                $new_points += $bonus;
                $new_points = $max_points if $new_points > $max_points;
                $new_points = sprintf("%.2f", $new_points);
            }

            $potential_points = $new_points;
        } else {
            $countdown = "Calculating...";
            $potential_points = 25;
        }
    } else {
        $countdown = "Calculating...";
        $potential_points = 0;
    }

    set_local_storage({ potentialPoints => $potential_points, countdown => $countdown });
}

sub get_user_id {
    my $login_url = "https://ikknngrgxuxgjhplbpey.supabase.co/auth/v1/token?grant_type=password";
    my $authorization = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag";
    my $apikey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag";

    my $email = $term->readline("Email: ");
    my $password = $term->readline("Password: ");

    my $ua = LWP::UserAgent->new;
    my $response = $ua->request(
        POST $login_url,
        Content_Type => 'application/json',
        Content => encode_json({ email => $email, password => $password }),
        'Authorization' => $authorization,
        'apikey' => $apikey
    );

    if ($response->is_success) {
        my $data = decode_json($response->content);
        my $user_id = $data->{user}{id};
        print "User ID: $user_id\n";

        my $profile_url = "https://ikknngrgxuxgjhplbpey.supabase.co/rest/v1/profiles?select=personal_code&id=eq.$user_id";
        my $profile_response = $ua->request(
            GET $profile_url,
            'Authorization' => $authorization,
            'apikey' => $apikey
        );

        if ($profile_response->is_success) {
            my $profile_data = decode_json($profile_response->content);
            print "Profile Data: ", encode_json($profile_data), "\n";
            set_local_storage({ userId => $user_id });
            start_countdown_and_points();
            connect_websocket($user_id);
        } else {
            print "Error fetching profile: ", $profile_response->status_line, "\n";
        }
    } else {
        print "Error: ", $response->status_line, "\n";
    }
}

sub main {
    my $local_storage_data = get_local_storage();
    my $user_id = $local_storage_data->{userId};

    if (!$user_id) {
        my $option = $term->readline("User ID not found. Would you like to:\n1. Login to your account\n2. Enter User ID manually\nChoose an option: ");
        if ($option == 1) {
            get_user_id();
        } elsif ($option == 2) {
            $user_id = $term->readline("Please enter your user ID: ");
            set_local_storage({ userId => $user_id });
            start_countdown_and_points();
            connect_websocket($user_id);
        } else {
            print "Invalid option. Exiting...\n";
            exit 0;
        }
    } else {
        my $option = $term->readline("Menu:\n1. Logout\n2. Start Running Node\nChoose an option: ");
        if ($option == 1) {
            unlink 'localStorage.json';
            print "Logged out successfully.\n";
            exit 0;
        } elsif ($option == 2) {
            start_countdown_and_points();
            connect_websocket($user_id);
        } else {
            print "Invalid option. Exiting...\n";
            exit 0;
        }
    }
}

main();

