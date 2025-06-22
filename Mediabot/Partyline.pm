package Mediabot::Partyline;

use strict;
use warnings;
use IO::Async::Listener;
use IO::Async::Stream;
use Scalar::Util qw(weaken);
use JSON;
use Exporter 'import';

our @EXPORT_OK = qw();

sub new {
    my ($class, %args) = @_;
    my $self = {
        bot   => $args{bot},    # reference to the Mediabot object
        loop  => $args{loop},   # IO::Async::Loop
        port  => $args{port} || 23456,
        users => {},            # session storage
    };
    bless $self, $class;

    $self->_start_listener;

    return $self;
}

sub get_port {
    my ($self) = @_;
    return $self->{bot}->{conf}->get("main.PARTYLINE_PORT") || 23456;
}

sub _start_listener {
    my ($self) = @_;
    my $loop = $self->{loop};
    my $bot  = $self->{bot};
    weaken($bot);

    $loop->listen(
        service  => $self->{port},
        socktype => 'stream',
        on_stream => sub {
            my ($stream) = @_;
            my $id = fileno($stream->read_handle);
            $self->{users}{$id} = {
                authenticated => 0,
                login         => '',
                buffer        => '',
            };

            $stream->configure(
                on_read => sub {
                    my ($stream, $buffref, $eof) = @_;
                    while ($$buffref =~ s/^(.*)\n//) {
                        my $line = $1;
                        $self->{bot}->{logger}->log(3, "Partyline <- $line (fd=$id)");
                        eval {
                            $self->_handle_line($stream, $id, $line);
                        };
                        if ($@) {
                            $self->{bot}->{logger}->log(1, "Partyline exception: $@");
                            $stream->write("💥 Internal error: $@\n");
                        }
                    }
                    return 0;
                },
                on_closed => sub {
                    $self->{bot}->{logger}->log(3, "Partyline connection closed (fd=$id)");
                    delete $self->{users}{$id};
                },
            );

            $stream->write("👋 Welcome to Mediabot partyline. Use 'login <user> <pass>' to authenticate.\n");

            $self->{loop}->add($stream);  # 🔥 essentiel pour que le stream fonctionne
            return $stream;
        },
    )->get;  # attendre le future pour s'assurer du binding correct
}

sub _handle_line {
    my ($self, $stream, $id, $line) = @_;
    $line =~ s/\r$//;

    my $user = $self->{users}{$id};

    unless ($user->{authenticated}) {
        if ($line =~ /^login\s+(\S+)\s+(\S+)$/) {
            my ($login, $password) = ($1, $2);
            my $id_user = $self->{bot}->getIdUser($login);

            if ($id_user && $self->{bot}->{auth}->verify_credentials($id_user, $login, $password)) {
                $user->{authenticated} = 1;
                $user->{login} = $login;
                $stream->write("✅ Authenticated as $login\nType .help for available commands.\n");
                $self->{bot}->{logger}->log(2, "Partyline: $login authenticated (fd=$id)");
            } else {
                $stream->write("❌ Authentication failed\n");
                $self->{bot}->{logger}->log(2, "Partyline: failed auth attempt for $login (fd=$id)");
            }
        } else {
            $stream->write("Please login using: login <user> <pass>\n");
        }
        return;
    }

    if ($line eq '.stat') {
        # Get the bot's current nickname (folded form)
        my $nick = $self->{bot}->{irc}->nick_folded;

        # Store the current stream in the Partyline object, indexed by file descriptor
        # This will allow the WHOIS response handler to send data back to the user
        $self->{streams}{$id} = $stream;

        # Prepare the WHOIS_VARS used to track this WHOIS request
        my %WHOIS_VARS = (
            nick    => $nick,
            caller  => $id,
            sub     => "statPartyline",   # Stub: response handler should match on this
            message => undef,             # Stub: will hold original IRC message if needed
            channel => undef,             # Not required for stat
        );

        # Set the WHOIS_VARS hash in the bot object (used later in IRC WHOIS response)
        %{ $self->{bot}->{WHOIS_VARS} } = %WHOIS_VARS;

        # Send the WHOIS request for our own bot nick
        #$self->{bot}->{irc}->send_message("WHOIS", undef, $nick);

        # Inform the user we are waiting for a reply from the IRC server
        $stream->write("⌛ Retrieving channel status from IRC...\n");
    }
    elsif ($line eq '.help') {
        $stream->write(".stat - Show bot channel join status\n.help - Show this help message\n");
    }
    else {
        $stream->write("Unknown command. Type .help for a list of available commands.\n");
    }

}


1;
