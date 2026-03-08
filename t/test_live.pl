#!/usr/bin/perl
# =============================================================================
#  Mediabot v3 - Framework de test live IRC
#  Usage : perl t/test_live.pl [options]
#
#  Ce runner :
#    1. Vérifie la connectivité IRC (fail hard si KO)
#    2. Crée la base mediabot_test depuis t/live/schema_test.sql
#    3. Génère t/live/test.conf depuis t/live/test.conf.tpl
#    4. Lance le bot en subprocess (fork+exec)
#    5. Connecte un client spy IRC pour observer les réponses
#    6. Exécute les closures t/live/*.t dans l'ordre
#    7. Teardown propre (bot SIGTERM, spy QUIT, DB optionnelle)
# =============================================================================

BEGIN {
    require FindBin;
    unshift @INC, "$FindBin::Bin/lib";
    unshift @INC, "$FindBin::Bin/..";
}

use strict;
use warnings;
use Getopt::Long;
use File::Basename;
use File::Slurp qw(read_file write_file);
use IO::Socket::INET;
use IO::Select;
use POSIX qw(strftime WNOHANG);
use Time::HiRes qw(sleep time);

# ---------------------------------------------------------------------------
# Options CLI
# ---------------------------------------------------------------------------
my $opt_verbose      = 0;
my $opt_filter       = '';
my $opt_server       = 'irc.libera.chat';
my $opt_port         = 6667;
my $opt_channel      = '##mbtest';
my $opt_botnick      = '';          # généré aléatoirement si vide
my $opt_spynick      = '';          # généré aléatoirement si vide
my $opt_cmdchar      = '!';
my $opt_timeout      = 30;
my $opt_dbhost       = 'localhost';
my $opt_dbport       = 3306;
my $opt_dbuser       = 'mediabot_test';
my $opt_dbpass       = '';
my $opt_keep_db      = 0;

GetOptions(
    'verbose|v'    => \$opt_verbose,
    'filter|f=s'   => \$opt_filter,
    'server|s=s'   => \$opt_server,
    'port=i'       => \$opt_port,
    'channel|c=s'  => \$opt_channel,
    'botnick|b=s'  => \$opt_botnick,
    'spynick=s'    => \$opt_spynick,
    'cmdchar=s'    => \$opt_cmdchar,
    'timeout|t=i'  => \$opt_timeout,
    'dbhost=s'     => \$opt_dbhost,
    'dbport=i'     => \$opt_dbport,
    'dbuser=s'     => \$opt_dbuser,
    'dbpass=s'     => \$opt_dbpass,
    'keep-db'      => \$opt_keep_db,
) or die usage();

sub usage {
    return <<'END';
Usage: perl t/test_live.pl [options]

  IRC:
    --server,  -s <host>   Serveur IRC          (défaut: irc.libera.chat)
    --port        <port>   Port IRC             (défaut: 6667)
    --channel, -c <chan>   Canal de test        (défaut: ##mbtest)
    --botnick, -b <nick>   Nick du bot          (défaut: mbtest_XXXX)
    --spynick     <nick>   Nick du spy          (défaut: mbspy_XXXX)
    --cmdchar     <char>   Caractère commande   (défaut: !)
    --timeout, -t <sec>    Timeout par réponse  (défaut: 30)

  Base de données:
    --dbhost      <host>   Hôte MariaDB         (défaut: localhost)
    --dbport      <port>   Port MariaDB         (défaut: 3306)
    --dbuser      <user>   Utilisateur MariaDB  (défaut: root)
    --dbpass      <pass>   Mot de passe MariaDB (défaut: sudo mysql)
    --keep-db              Conserver mediabot_test après les tests

  Général:
    --verbose, -v          Afficher chaque test [OK]/[FAIL]
    --filter,  -f <pat>    Lancer uniquement les .t matching <pat>

END
}

# ---------------------------------------------------------------------------
# Nicks aléatoires
# ---------------------------------------------------------------------------
my $rand_suffix = sprintf("%04d", int(rand(9999)));
$opt_botnick ||= "mbtest_$rand_suffix";
$opt_spynick ||= "mbspy_$rand_suffix";

# ---------------------------------------------------------------------------
# Chemins
# ---------------------------------------------------------------------------
my $base_dir    = "$FindBin::Bin";
my $live_dir    = "$base_dir/live";
my $schema_file = "$live_dir/schema_test.sql";
my $tpl_file    = "$live_dir/test.conf.tpl";
my $conf_file   = "$live_dir/test.conf";
my $log_file    = "$live_dir/bot.log";
my $bot_script  = "$base_dir/../mediabot.pl";
my $cases_dir   = "$live_dir";

die "ERROR: $schema_file not found\n" unless -f $schema_file;
die "ERROR: $tpl_file not found\n"    unless -f $tpl_file;
die "ERROR: $bot_script not found\n"  unless -f $bot_script;

# ---------------------------------------------------------------------------
# Classe d'assertion
# ---------------------------------------------------------------------------
package Assert;

sub new {
    my ($class, %args) = @_;
    return bless { verbose => $args{verbose} // 0, pass => 0, fail => 0 }, $class;
}

sub _result {
    my ($self, $ok, $desc, $extra) = @_;
    if ($ok) {
        $self->{pass}++;
        print "  [OK] $desc\n" if $self->{verbose};
    } else {
        $self->{fail}++;
        my $msg = "  [FAIL] $desc";
        $msg .= " ($extra)" if $extra;
        print "$msg\n";
    }
}

sub ok   { $_[0]->_result($_[1] ? 1 : 0, $_[2] // '', '') }
sub is   { my ($s,$g,$e,$d)=@_; $s->_result(defined $g && $g eq $e, $d//'', "got='".($g//'undef')."' exp='$e'") }
sub like { my ($s,$g,$p,$d)=@_; $s->_result(defined $g && $g =~ /$p/, $d//'', "got='".($g//'undef')."'") }

sub pass { $_[0]->_result(1, $_[1] // '(pass)') }
sub fail { $_[0]->_result(0, $_[1] // '(fail)') }

sub total  { $_[0]->{pass} + $_[0]->{fail} }
sub passed { $_[0]->{pass} }
sub failed { $_[0]->{fail} }

# ---------------------------------------------------------------------------
# Classe SpyClient — client IRC minimal (PING/PONG, JOIN, PRIVMSG, lecture)
# ---------------------------------------------------------------------------
package SpyClient;

sub new {
    my ($class, %args) = @_;
    return bless {
        server  => $args{server},
        port    => $args{port},
        nick    => $args{nick},
        channel => $args{channel},
        sock    => undef,
        buf     => '',
        joined  => 0,
    }, $class;
}

sub connect {
    my ($self) = @_;
    my $sock = IO::Socket::INET->new(
        PeerAddr => $self->{server},
        PeerPort => $self->{port},
        Proto    => 'tcp',
        Timeout  => 10,
    ) or die "ERROR: Cannot connect to $self->{server}:$self->{port} : $!\n"
           . "Check your network or try again later.\n";
    $sock->autoflush(1);
    # Utiliser un filehandle buffered pour readline fiable
    $self->{sock} = $sock;
    $self->{sel}  = IO::Select->new($sock);
    $self->send_raw("NICK $self->{nick}");
    $self->send_raw("USER spy 0 * :Mediabot Test Spy");
    return $self;
}

sub send_raw {
    my ($self, $line) = @_;
    $self->{sock}->print("$line\r\n");
}

sub privmsg {
    my ($self, $target, $text) = @_;
    $self->send_raw("PRIVMSG $target :$text");
}

sub join_channel {
    my ($self) = @_;
    $self->send_raw("JOIN $self->{channel}");
}

sub quit {
    my ($self, $msg) = @_;
    $msg //= 'Test done';
    eval { $self->send_raw("QUIT :$msg") };
    eval { close $self->{sock} };
}

# Lire une ligne avec timeout (IO::Select + sysread + buffer interne)
# Répond automatiquement aux PINGs
sub read_line {
    my ($self, $timeout) = @_;
    $timeout //= 1;
    my $deadline = main::time() + $timeout;

    while (1) {
        # Vider le buffer : extraire toutes les lignes disponibles
        while ($self->{buf} =~ s/^(.*?)\r?\n//) {
            my $line = $1;
            if ($line =~ /^PING (.+)/) {
                $self->send_raw("PONG $1");
                next;  # continuer à vider le buffer
            }
            return $line;  # ligne utile trouvée
        }
        # Buffer vide — attendre de nouvelles données
        my $remaining = $deadline - main::time();
        return undef if $remaining <= 0;
        next unless $self->{sel}->can_read($remaining > 1 ? 1 : $remaining);
        my $chunk = '';
        my $n = $self->{sock}->sysread($chunk, 4096);
        return undef unless defined $n && $n > 0;
        $self->{buf} .= $chunk;
    }
}

# Attendre qu'un message matche $pattern, avec timeout global
sub wait_for {
    my ($self, $pattern, $timeout) = @_;
    $timeout //= 30;
    my $deadline = main::time() + $timeout;
    while (main::time() < $deadline) {
        my $remaining = $deadline - main::time();
        last if $remaining <= 0;
        my $line = $self->read_line($remaining > 1 ? 1 : $remaining);
        next unless defined $line;
        print "  [SPY RECV] $line\n" if $main::opt_verbose;
        return $line if $line =~ $pattern;
    }
    return undef;
}

# Attendre le JOIN du bot sur le canal
sub wait_for_bot_join {
    my ($self, $botnick, $timeout) = @_;
    return $self->wait_for(qr/^:\Q$botnick\E[!@][^ ]+ JOIN/i, $timeout);
}

# ---------------------------------------------------------------------------
# Package principal
# ---------------------------------------------------------------------------
package main;

binmode(STDOUT, ':encoding(UTF-8)');

# ---------------------------------------------------------------------------
# Étape 1 : vérifier connectivité IRC (fail hard)
# ---------------------------------------------------------------------------
print "[ Checking IRC connectivity to $opt_server:$opt_port ]\n";
my $test_sock = IO::Socket::INET->new(
    PeerAddr => $opt_server,
    PeerPort => $opt_port,
    Proto    => 'tcp',
    Timeout  => 10,
);
die "ERROR: Cannot reach $opt_server:$opt_port\n"
  . "Check your network connectivity and try again.\n"
  unless $test_sock;
close $test_sock;
print "  IRC server reachable.\n";

# ---------------------------------------------------------------------------
# Étape 2 : créer la base mediabot_test
# ---------------------------------------------------------------------------
print "[ Setting up mediabot_test database ]\n";

# Fonction pour exécuter une commande mysql
sub mysql_cmd {
    my ($sql) = @_;
    # Passer le SQL via un fichier temporaire pour eviter les problemes de quoting
    my $tmpfile = "/tmp/mediabot_test_$$.sql";
    open(my $fh, '>', $tmpfile) or die "Cannot write $tmpfile: $!\n";
    print $fh $sql;
    close $fh;
    my $output;
    if ($opt_dbpass ne '') {
        $output = `mysql -u$opt_dbuser -p$opt_dbpass < $tmpfile 2>&1`;
    } else {
        $output = `sudo mysql < $tmpfile 2>&1`;
    }
    my $rc = $?;
    unlink $tmpfile;
    return ($rc == 0, $output);
}

sub mysql_cmd_file {
    my ($dbname, $file) = @_;
    my $output;
    if ($opt_dbpass ne '') {
        $output = `mysql -u$opt_dbuser -p$opt_dbpass $dbname < $file 2>&1`;
    } else {
        $output = `sudo mysql $dbname < $file 2>&1`;
    }
    return ($? == 0, $output);
}

# DROP + CREATE
# DROP + CREATE database
my ($ok, $out) = mysql_cmd("DROP DATABASE IF EXISTS mediabot_test");
unless ($ok) {
    if ($out =~ /access denied|cannot connect/i) {
        die "ERROR: Cannot connect to MariaDB.\n"
          . "If you have already removed sudo rights from the mediabot user, run:\n"
          . "  perl t/test_live.pl --dbpass <your_password>\n";
    }
    die "ERROR: Failed to drop mediabot_test:\n$out\n";
}
($ok, $out) = mysql_cmd("CREATE DATABASE mediabot_test CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
unless ($ok) {
    die "ERROR: Failed to create mediabot_test database:\n$out\n";
}

# Créer un user dédié sans mot de passe pour le bot
mysql_cmd("DROP USER IF EXISTS 'mediabot_test'\@'localhost'");
($ok, $out) = mysql_cmd("CREATE USER IF NOT EXISTS 'mediabot_test'\@'localhost' IDENTIFIED BY ''");
die "ERROR: Failed to create DB user mediabot_test:\n$out\n" unless $ok;
($ok, $out) = mysql_cmd("GRANT ALL PRIVILEGES ON mediabot_test.* TO 'mediabot_test'\@'localhost'");
die "ERROR: Failed to grant privileges:\n$out\n" unless $ok;
mysql_cmd("FLUSH PRIVILEGES");
print "  Database mediabot_test created (user: mediabot_test, no password).\n";

# Charger le schéma
($ok, $out) = mysql_cmd_file('mediabot_test', $schema_file);
die "ERROR: Failed to load schema:\n$out\n" unless $ok;
print "  Schema loaded.\n";

# ---------------------------------------------------------------------------
# Étape 3 : trouver un port libre pour Partyline
# ---------------------------------------------------------------------------
sub find_free_port {
    my $sock = IO::Socket::INET->new(
        LocalAddr => 'localhost',
        LocalPort => 0,
        Proto     => 'tcp',
    ) or return 23456;
    my $port = $sock->sockport;
    close $sock;
    return $port;
}
my $partyline_port = find_free_port();

# ---------------------------------------------------------------------------
# Étape 4 : générer test.conf depuis le template
# ---------------------------------------------------------------------------
print "[ Generating test.conf ]\n";
my $tpl = read_file($tpl_file);
$tpl =~ s/\{\{BOTNICK\}\}/$opt_botnick/g;
$tpl =~ s/\{\{CMDCHAR\}\}/$opt_cmdchar/g;
$tpl =~ s/\{\{DBUSER\}\}/$opt_dbuser/g;
$tpl =~ s/\{\{DBHOST\}\}/$opt_dbhost/g;
$tpl =~ s/\{\{DBPASS\}\}/$opt_dbpass/g;
$tpl =~ s/\{\{DBPORT\}\}/$opt_dbport/g;
$tpl =~ s/\{\{LOGFILE\}\}/$log_file/g;
$tpl =~ s/\{\{PARTYLINE_PORT\}\}/$partyline_port/g;

# Mettre à jour le canal dans la DB
my $channel_esc = $opt_channel;
$channel_esc =~ s/'/\\'/g;
mysql_cmd("UPDATE mediabot_test.CHANNEL SET name='$channel_esc' WHERE id_channel=1");
mysql_cmd("UPDATE mediabot_test.SERVERS SET server_hostname='$opt_server:$opt_port' WHERE id_server=1");

write_file($conf_file, $tpl);
print "  test.conf generated (botnick=$opt_botnick, channel=$opt_channel).\n";

# ---------------------------------------------------------------------------
# Étape 5 : connecter le spy IRC
# ---------------------------------------------------------------------------
print "[ Connecting spy client ($opt_spynick) to $opt_server:$opt_port ]\n";
my $spy = SpyClient->new(
    server  => $opt_server,
    port    => $opt_port,
    nick    => $opt_spynick,
    channel => $opt_channel,
);
$spy->connect;

# Attendre le 001 (welcome)
my $welcomed = $spy->wait_for(qr/^:.*001 \Q$opt_spynick\E/, 30);
die "ERROR: Spy client did not receive IRC welcome (001). Server issue?\n"
    unless $welcomed;
print "  Spy connected.\n";

$spy->join_channel;
my $spy_joined = $spy->wait_for(qr/JOIN.*\Q$opt_channel\E/i, 15);
die "ERROR: Spy could not join $opt_channel\n" unless $spy_joined;
print "  Spy joined $opt_channel.\n";

# ---------------------------------------------------------------------------
# Étape 6 : lancer le bot en subprocess
# ---------------------------------------------------------------------------
print "[ Starting bot subprocess ($opt_botnick) ]\n";
unlink $log_file if -f $log_file;

my $bot_pid = fork;
die "ERROR: fork failed: $!\n" unless defined $bot_pid;

if ($bot_pid == 0) {
    # Enfant : exec le bot
    open(STDOUT, '>>', $log_file) or die;
    open(STDERR, '>>', $log_file) or die;
    exec $^X, $bot_script, "--conf=$conf_file"
        or die "ERROR: exec failed: $!\n";
}

print "  Bot PID=$bot_pid launched.\n";

# Attendre le JOIN du bot sur le canal
print "  Waiting for bot to join $opt_channel (timeout=${opt_timeout}s)...\n";
my $bot_joined = $spy->wait_for_bot_join($opt_botnick, $opt_timeout);
unless ($bot_joined) {
    teardown(1);
    die "ERROR: Bot did not join $opt_channel within ${opt_timeout}s.\n"
      . "Check $log_file for details.\n";
}
print "  Bot joined $opt_channel.\n";

# ---------------------------------------------------------------------------
# Étape 7 : exécuter les closures live/*.t
# ---------------------------------------------------------------------------
my $assert   = Assert->new(verbose => $opt_verbose);
my $ts_start = time();

# Callbacks passés aux closures
my $send_cmd = sub {
    my ($cmd) = @_;
    $spy->privmsg($opt_channel, "$opt_cmdchar$cmd");
};

my $wait_reply = sub {
    my ($pattern, $timeout) = @_;
    $timeout //= $opt_timeout;
    return $spy->wait_for($pattern, $timeout);
};

my $send_private = sub {
    my ($cmd) = @_;
    $spy->privmsg($opt_botnick, "$cmd");  # Pas de cmdchar en PRIVMSG prive
};

my @test_files = sort grep {
    my $name = basename($_);
    !$opt_filter || $name =~ /\Q$opt_filter\E/
} glob("$cases_dir/*.t");

if (!@test_files) {
    print "No test files found in $cases_dir/\n";
} else {
    # Silencer les warnings internes au bot
    local $SIG{__WARN__} = sub {
        my $w = shift;
        return if $w =~ /uninitialized|redefine|prototype|only once/i;
        warn $w;
    };

    for my $file (@test_files) {
        my $name = basename($file);
        print "\n[ $name ]\n";

        my $code = do $file;
        if ($@) {
            print "  ERREUR de chargement : $@\n";
            $assert->fail("$name: chargement");
            next;
        }
        if (ref $code eq 'CODE') {
            $code->($assert, $spy, $send_cmd, $send_private, $wait_reply,
                    $opt_botnick, $opt_spynick, $opt_channel, $opt_cmdchar);
        } else {
            print "  (pas de sous-routine retournée, skip)\n";
        }
    }
}

# ---------------------------------------------------------------------------
# Teardown et rapport
# ---------------------------------------------------------------------------
my $elapsed = time() - $ts_start;
teardown(0);

my $total  = $assert->total;
my $passed = $assert->passed;
my $failed = $assert->failed;
my $secs   = sprintf("%.0f", $elapsed);

print "\n" . "=" x 60 . "\n";
if ($failed == 0) {
    print "PASSED : $passed/$total  (${secs}s)\n";
} else {
    print "FAILED : $failed/$total  ($passed passed)  (${secs}s)\n";
}
print "=" x 60 . "\n";

exit($failed > 0 ? 1 : 0);

# ---------------------------------------------------------------------------
# Teardown : arrêter le bot, quitter le spy, nettoyer
# ---------------------------------------------------------------------------
sub teardown {
    my ($hard) = @_;

    # Spy QUIT
    eval { $spy->quit('Test suite finished') } if $spy;

    # Arrêter le bot subprocess
    if ($bot_pid) {
        print "\n[ Stopping bot (PID=$bot_pid) ]\n" unless $hard;
        kill 'TERM', $bot_pid;
        my $waited = 0;
        while ($waited < 10) {
            my $res = waitpid($bot_pid, WNOHANG);
            last if $res == $bot_pid;
            sleep(0.5);
            $waited += 0.5;
        }
        # Force kill si toujours vivant
        if (kill(0, $bot_pid)) {
            kill 'KILL', $bot_pid;
            waitpid($bot_pid, 0);
        }
        $bot_pid = 0;
    }

    # Nettoyer test.conf
    unlink $conf_file if -f $conf_file;

    # Supprimer la DB (sauf --keep-db)
    unless ($opt_keep_db) {
        mysql_cmd("DROP DATABASE IF EXISTS mediabot_test");
        mysql_cmd("DROP USER IF EXISTS 'mediabot_test'\@'localhost'");
        mysql_cmd("FLUSH PRIVILEGES");
        print "  mediabot_test dropped.\n" unless $hard;
    } else {
        print "  mediabot_test kept (--keep-db).\n" unless $hard;
    }
}

# Teardown sur Ctrl+C
$SIG{INT} = $SIG{TERM} = sub {
    print "\n[ Interrupted — cleaning up ]\n";
    teardown(1);
    exit 1;
};