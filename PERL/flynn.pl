use strict;
use warnings;
use JSON;
use IO::Prompter;
use IO::Socket::SSL;
use Time::HiRes qw(sleep);
use File::Slurp;

my %cl = (
    gr => "\x1b[32m",
    gb => "\x1b[4m",
    br => "\x1b[34m",
    st => "\x1b[9m",
    yl => "\x1b[33m",
    rt => "\x1b[0m"
);

my $socket = undef;
my $ping_interval;
my $countdown_interval;
my $potential_points = 0;
my $countdown = "Calculating...";
my $points_total = 0;
my $points_today = 0;
my $reconnect_attempts = 0;
my $max_reconnect_attempts = 5;
my $max_reconnect_interval = 5 * 60; # 5 minutes in seconds
my $CoderMarkPrinted = 0;

sub CoderMark {
    return if $CoderMarkPrinted;
    print "\n╭━━━╮╱╱╱╱╱╱╱╱╱╱╱╱╱╭━━━┳╮
┃╭━━╯╱╱╱╱╱╱╱╱╱╱╱╱╱┃╭━━┫┃$cl{gr}
┃╰━━┳╮╭┳━┳━━┳━━┳━╮┃╰━━┫┃╭╮╱╭┳━╮╭━╮
┃╭━━┫┃┃┃╭┫╭╮┃╭╮┃╭╮┫╭━━┫┃┃┃╱┃┃╭╮┫╭╮╮$cl{br}
┃┃╱╱┃╰╯┃┃┃╰╯┃╰╯┃┃┃┃┃╱╱┃╰┫╰━╯┃┃┃┃┃┃┃
╰╯╱╱╰━━┻╯╰━╮┣━━┻╯╰┻╯╱╱╰━┻━╮╭┻╯╰┻╯╰╯$cl{rt}
╱╱╱╱╱╱╱╱╱╱╱┃┃╱╱╱╱╱╱╱╱╱╱╱╭━╯┃
╱╱╱╱╱╱╱╱╱╱╱╰╯╱╱╱╱╱╱╱╱╱╱╱╰━━╯
\n$cl{gb}Teneo Node Cli $cl{gr}v1.1.0 $cl{rt}$cl{gb}$cl{br}dev_build$cl{rt}\n";
    $CoderMarkPrinted = 1;
}

sub read_file {
    my ($file) = @_;
    return decode_json(read_file($file)) if -e $file;
    return {};
}

sub write_file {
    my ($file, $data) = @_;
    write_file($file, encode_json($data));
}

sub get_local_storage {
    return read_file('localStorage.json');
}

sub set_local_storage {
    my ($data) = @_;
    my $current_data = get_local_storage();
    my %new_data = (%$current_data, %$data);
    write_file('localStorage.json', \%new_data);
}

sub get_user_id_from_file {
    my $data = read_file('UserId.json');
    return $data->{userId} if $data->{userId};
    return undef;
}

sub set_user_id_to_file {
    my ($user_id) = @_;
    write_file('UserId.json', { userId => $user_id });
}

sub get_account_data {
    return read_file('DataAccount.json');
}

sub set_account_data {
    my ($email, $password, $access_token, $refresh_token, $personal_code) = @_;
    my %account_data = (
        email => $email,
        password => $password,
        access_token => $access_token,
        refresh_token => $refresh_token,
        personalCode => $personal_code
    );
    write_file('DataAccount.json', \%account_data);
}

sub get_reconnect_delay {
    my ($attempt) = @_;
    my $base_delay = 5; # 5 seconds
    my $additional_delay = $attempt * 5; # Additional 5 seconds for each attempt
    return $base_delay + $additional_delay < $max_reconnect_interval ? $base_delay + $additional_delay : $max_reconnect_interval;
}

sub connect_websocket {
    my ($user_id) = @_;
    return if $socket;

    my $version = "v0.2";
    my $url = "wss://secure.ws.teneo.pro/websocket?userId=" . uri_escape($user_id) . "&version=" . uri_escape($version);
    $socket = IO::Socket::SSL->new(PeerAddr => $url) or die "Could not connect to WebSocket: $!";

    # Handle WebSocket events
    # Note: WebSocket handling in Perl is more complex and may require additional libraries
}

sub disconnect_websocket {
    if ($socket) {
        close($socket);
        $socket = undef;
        stop_pinging();
    }
}

sub start_pinging {
    stop_pinging();
    $ping_interval = AnyEvent->timer(0, 10, sub {
        if ($socket) {
            my $ping_message = encode_json({ type => "PING" });
            print $socket $ping_message;
            set_local_storage({ lastPingDate => time() });
        }
    });
}

sub stop_pinging {
    if ($ping_interval) {
        undef $ping_interval;
    }
}

sub signal_handler {
    print 'Received SIGINT. Stopping pinging...';
    stop_pinging();
    disconnect_websocket();
    exit(0);
}

$SIG{INT} = \&signal_handler;

sub start_countdown_and_points {
    stop_countdown();
    update_countdown_and_points();
    $countdown_interval = AnyEvent->timer(0, 1, \&update_countdown_and_points);
}

sub update_countdown_and_points {
    my $local_storage = get_local_storage();
    if ($local_storage->{lastUpdated}) {
        my $next_heartbeat = $local_storage->{lastUpdated} + 15 * 60; # 15 minutes
        my $now = time();
        my $diff = $next_heartbeat - $now;

        if ($diff > 0) {
            my $minutes = int($diff / 60);
            my $seconds = $diff % 60;
            $countdown = "${minutes}m ${seconds}s";

            my $max_points = 25;
            my $time_elapsed = $now - $local_storage->{lastUpdated};
            my $time_elapsed_minutes = $time_elapsed / 60;
            my $new_points = $max_points < ($time_elapsed_minutes / 15) * $max_points ? $max_points : ($time_elapsed_minutes / 15) * $max_points;
            $new_points = sprintf("%.2f", $new_points);

            if (rand() < 0.1) {
                my $bonus = rand() * 2;
                $new_points = $max_points < ($new_points + $bonus) ? $max_points : ($new_points + $bonus);
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
    my $login_url = "https://node-community-api.teneo.pro/auth/v1/token?grant_type=password";
    my $authorization = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag";
    my $apikey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag";

    my $account_data = get_account_data();
    my $email = $account_data->{email} || prompt('Email: ');
    my $password = $account_data->{password} || prompt('Password: ');

    my $response = HTTP::Tiny->new->post($login_url, {
        headers => {
            'Authorization' => $authorization,
            'apikey' => $apikey
        },
        content => encode_json({ email => $email, password => $password })
    });

    if ($response->{success}) {
        my $data = decode_json($response->{content});
        my $access_token = $data->{access_token};
        my $refresh_token = $data->{refresh_token};
        print "Access_Token: $access_token\n";
        print "Refresh_Token: $refresh_token\n";

        my $AuthUserUrl = "https://node-community-api.teneo.pro/auth/v1/user";
        my $AuthResponse = HTTP::Tiny->new->get($AuthUserUrl, {
            headers => {
                'Authorization' => "Bearer $access_token",
                'apikey' => $apikey
            }
        });

        if ($AuthResponse->{success}) {
            my $user_data = decode_json($AuthResponse->{content});
            my $user_id = $user_data->{id};
            print "User ID: $user_id\n";

            my $profile_url = "https://node-community-api.teneo.pro/rest/v1/profiles?select=personal_code&id=eq.$user_id";
            my $profile_response = HTTP::Tiny->new->get($profile_url, {
                headers => {
                    'Authorization' => "Bearer $access_token",
                    'apikey' => $apikey
                }
            });

            if ($profile_response->{success}) {
                my $profile_data = decode_json($profile_response->{content});
                my $personal_code = $profile_data->[0]->{personal_code};
                print "Personal Code: $personal_code\n";
                set_user_id_to_file($user_id);
                set_account_data($email, $password, $access_token, $refresh_token, $personal_code);
                start_countdown_and_points();
                connect_websocket($user_id);
                print "$cl{gr}Data has been saved in the DataAccount.json file...\n$cl{rt}";
                CoderMark();
            }
        } else {
            print "Error: " . $response->{reason} . "\n";
        }
    }
}

sub reconnect_websocket {
    my $user_id = get_user_id_from_file();
    connect_websocket($user_id) if $user_id;
}

sub auto_login {
    my $account_data = get_account_data();
    if ($account_data->{email} && $account_data->{password}) {
        get_user_id();
        print "$cl{yl}\nAutomatic Login has been Successfully Executed..\n$cl{rt}";
    }
}

sub main {
    my $local_storage_data = get_local_storage();
    my $user_id = get_user_id_from_file();

    if (!$user_id) {
        my $option = prompt("\nUser ID not found. Would you like to:\n$cl{gr}\n1. Login to your account\n2. Enter User ID manually\n$cl{rt}\nChoose an option: ");
        if ($option == 1) {
            get_user_id();
        } elsif ($option == 2) {
            my $input_user_id = prompt('Please enter your user ID: ');
            set_user_id_to_file($input_user_id);
            start_countdown_and_points();
            connect_websocket($input_user_id);
        } else {
            print "Invalid option. Exiting...\n";
            exit(0);
        }
    } else {
        my $option = prompt("\nMenu:\n$cl{gr}\n1. Logout\n2. Start Running Node\n$cl{rt}\nChoose an option: ");
        if ($option == 1) {
            unlink 'UserId.json';
            unlink 'localStorage.json';
            unlink 'DataAccount.json';
            print "$cl{yl}\nLogged out successfully.\n";
            exit(0);
        } elsif ($option == 2) {
            CoderMark();
            print "$cl{gr}Initiates a connection to the node...\n$cl{rt}";
            start_countdown_and_points();
            connect_websocket($user_id);
        } else {
            print "$cl{yl}Invalid option. Exiting...\n";
            exit(0);
        }
    }
}

main();
AnyEvent->timer(0, 1800, \&auto_login);

