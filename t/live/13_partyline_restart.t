# t/live/13_partyline_restart.t
# =============================================================================
#  Partyline restart live test
#  Vérifie :
#    - connexion Partyline
#    - login Partyline
#    - .restart accepté
#    - QUIT IRC observé
#    - session Partyline toujours vivante après reconnect
#    - le bot redevient exploitable sur IRC après le restart
#
#  IMPORTANT :
#    .restart est Owner-only côté Partyline.
#    Le test promeut temporairement mboper -> Owner dans la DB de test,
#    puis restaure son niveau à la fin.
# =============================================================================

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Time::HiRes qw(time sleep);
use File::Basename qw(dirname);
use DBI;

return sub {
    my ($assert, $spy, $send_cmd, $send_private, $wait_reply,
        $botnick, $spynick, $channel, $cmdchar,
        $loginuser, $loginpass) = @_;

    my $conf_path = dirname(__FILE__) . '/test.conf';

    my %conf = _read_simple_ini($conf_path);
    my $partyline_port = $conf{main}{PARTYLINE_PORT};
    my $db_host        = $conf{mysql}{MAIN_PROG_DBHOST}  || 'localhost';
    my $db_port        = $conf{mysql}{MAIN_PROG_DBPORT}  || 3306;
    my $db_name        = $conf{mysql}{MAIN_PROG_DDBNAME} || 'mediabot_test';
    my $db_user        = $conf{mysql}{MAIN_PROG_DBUSER}  || 'mediabot_test';
    my $db_pass        = $conf{mysql}{MAIN_PROG_DBPASS}  || '';

    $assert->ok(defined $partyline_port && $partyline_port =~ /^\d+$/, "PARTYLINE_PORT lu depuis test.conf");

    my $dbh = DBI->connect(
        "DBI:mysql:database=$db_name;host=$db_host;port=$db_port",
        $db_user,
        $db_pass,
        {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
            mysql_enable_utf8mb4 => 1,
        }
    );

    $assert->ok(defined $dbh, "Connexion DBI à la base de test");

    my $orig_level = _fetch_user_level($dbh, $loginuser);
    $assert->ok(defined $orig_level, "Niveau initial de $loginuser récupéré");

    eval {
        my $sth = $dbh->prepare("UPDATE USER SET id_user_level = 1 WHERE nickname = ?");
        $sth->execute($loginuser);
        $sth->finish;
        1;
    };
    $assert->ok(!$@, "Promotion temporaire de $loginuser en Owner pour le test");

    my $pl = PartylineClient->new(
        host => '127.0.0.1',
        port => $partyline_port,
    );
    $pl->connect;

    my $line = $pl->wait_for(qr/Mediabot Partyline/i, 10);
    $assert->ok(defined $line, "Connexion Partyline OK (banner reçu)");

    $pl->send_line("login $loginuser $loginpass");
    $line = $pl->wait_for(qr/Authenticated as \Q$loginuser\E/i, 10);
    $assert->ok(defined $line, "Login Partyline OK pour $loginuser");

    _drain_partyline($pl, 1.5);

    $pl->send_line(".restart live test from t/live/13_partyline_restart.t");

    my $restart_ack = $pl->wait_for(
        qr/(?:Restarting IRC connection \(Partyline stays up\)|IRC restarting)/i,
        10
    );
    $assert->ok(defined $restart_ack, ".restart accepté côté Partyline");

    my $quit = $wait_reply->(qr/:\Q$botnick\E[!@][^ ]+ QUIT/i, 30);
    $assert->ok(defined $quit, "Après .restart, le bot quitte bien IRC (QUIT reçu)");

    $pl->send_line(".whom");
    my $whom = $pl->wait_for(qr/(?:Partyline users|$loginuser)/i, 20);
    $assert->ok(defined $whom, "La session Partyline reste vivante après le restart IRC");

    $pl->send_line(".help");
    my $help = $pl->wait_for(qr/Available commands/i, 15);
    $assert->ok(defined $help, "La Partyline répond encore aux commandes après le restart");

    # On ne dépend plus d'un JOIN forcément observable par le spy.
    # On vérifie à la place que le bot redevient réellement exploitable sur IRC.
    my $irc_back = _wait_until_bot_responds_on_channel(
        $send_cmd, $wait_reply, $botnick, $channel, 90
    );
    $assert->ok($irc_back, "Après .restart, le bot redevient exploitable sur IRC");

    eval {
        my $sth = $dbh->prepare("UPDATE USER SET id_user_level = ? WHERE nickname = ?");
        $sth->execute($orig_level, $loginuser);
        $sth->finish;
        1;
    };
    $assert->ok(!$@, "Restauration du niveau initial de $loginuser");

    eval { $pl->send_line(".quit") };
    eval { $pl->close };
    eval { $dbh->disconnect if $dbh };
};

# =============================================================================
# Helpers
# =============================================================================

sub _read_simple_ini {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!";

    my %cfg;
    my $section = '';

    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/\r$//;
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;

        next if $line eq '';
        next if $line =~ /^\#/;
        next if $line =~ /^\;/;

        if ($line =~ /^\[(.+)\]$/) {
            $section = $1;
            next;
        }

        next unless $line =~ /^([A-Za-z0-9_]+)\s*=\s*(.*)$/;
        my ($k, $v) = ($1, $2);
        $cfg{$section}{$k} = $v;
    }

    close $fh;
    return %cfg;
}

sub _fetch_user_level {
    my ($dbh, $nick) = @_;
    my $sth = $dbh->prepare("SELECT id_user_level FROM USER WHERE nickname = ?");
    $sth->execute($nick);
    my ($level) = $sth->fetchrow_array;
    $sth->finish;
    return $level;
}

sub _drain_partyline {
    my ($pl, $seconds) = @_;
    my $deadline = time() + ($seconds || 1);
    while (time() < $deadline) {
        my $line = $pl->read_line(0.25);
        last unless defined $line;
    }
}

sub _wait_until_bot_responds_on_channel {
    my ($send_cmd, $wait_reply, $botnick, $channel, $timeout) = @_;
    $timeout //= 90;

    my $deadline = time() + $timeout;
    my $attempt  = 0;

    while (time() < $deadline) {
        $attempt++;

        # On stimule doucement le bot
        $send_cmd->("version");

        my $line = $wait_reply->(
            qr/:\Q$botnick\E![^ ]+\s+PRIVMSG\s+\Q$channel\E\s+:(.+)/i,
            8
        );

        if (defined $line) {
            return 1 if $line =~ /Mediabot version|3\.\d|3\.2dev/i;
        }

        sleep 2;
    }

    return 0;
}

# =============================================================================
# Minimal Partyline TCP client
# =============================================================================
package PartylineClient;

sub new {
    my ($class, %args) = @_;
    return bless {
        host => $args{host} || '127.0.0.1',
        port => $args{port},
        sock => undef,
        sel  => undef,
        buf  => '',
    }, $class;
}

sub connect {
    my ($self) = @_;
    my $sock = IO::Socket::INET->new(
        PeerAddr => $self->{host},
        PeerPort => $self->{port},
        Proto    => 'tcp',
        Timeout  => 10,
    ) or die "Cannot connect to Partyline $self->{host}:$self->{port} : $!";

    $sock->autoflush(1);
    $self->{sock} = $sock;
    $self->{sel}  = IO::Select->new($sock);
    return $self;
}

sub send_line {
    my ($self, $line) = @_;
    die "Partyline socket not connected" unless $self->{sock};
    print { $self->{sock} } "$line\r\n";
}

sub read_line {
    my ($self, $timeout) = @_;
    $timeout //= 1;
    my $deadline = time() + $timeout;

    while (1) {
        while ($self->{buf} =~ s/^(.*?)\r?\n//) {
            my $line = $1;
            return $line;
        }

        my $remaining = $deadline - time();
        return undef if $remaining <= 0;

        next unless $self->{sel}->can_read($remaining > 1 ? 1 : $remaining);

        my $chunk = '';
        my $n = sysread($self->{sock}, $chunk, 4096);

        return undef unless defined $n;
        return undef if $n == 0;

        $self->{buf} .= $chunk;
    }
}

sub wait_for {
    my ($self, $pattern, $timeout) = @_;
    $timeout //= 10;
    my $deadline = time() + $timeout;
    my @seen;

    while (time() < $deadline) {
        my $line = $self->read_line(0.5);
        next unless defined $line;
        push @seen, $line;
        return $line if $line =~ $pattern;
    }

    if (@seen && !$main::opt_verbose) {
        print "  [DEBUG] Partyline timeout - lignes reçues :\n";
        print "    $_\n" for @seen;
    }

    return undef;
}

sub close {
    my ($self) = @_;
    eval { close $self->{sock} if $self->{sock} };
}

1;