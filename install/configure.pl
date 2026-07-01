#!/usr/bin/env perl

# mb378-R1: atomic IRC/network configuration updates without duplicate sections.

use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use DBI;
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use POSIX qw(strftime);

my $CONFIG_FILE;
my $HELP;
GetOptions(
    'conf=s' => \$CONFIG_FILE,
    'help'   => \$HELP,
) or die usage();

if ($HELP) {
    print usage();
    exit 0;
}
die usage() unless defined $CONFIG_FILE && length $CONFIG_FILE;
die "Configuration file not found: $CONFIG_FILE\n" unless -f $CONFIG_FILE;

my $APP_DIR = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $CONFIG_HELPER = File::Spec->catfile($Bin, 'configure_config.pl');
my $LOG_FILE = File::Spec->catfile($Bin, 'configure.log');

open my $LOG, '>>', $LOG_FILE or die "Cannot open $LOG_FILE: $!\n";
select((select($LOG), $| = 1)[0]);

my $cfg = parse_ini($CONFIG_FILE);
my $dbh = dbConnect(
    cfg('mysql.MAIN_PROG_DDBNAME', 1),
    cfg('mysql.MAIN_PROG_DBHOST', 1),
    cfg('mysql.MAIN_PROG_DBPORT', 1),
    cfg('mysql.MAIN_PROG_DBUSER', 1),
    cfg('mysql.MAIN_PROG_DBPASS', 0),
);

log_messageln("Connected to the Mediabot database. Existing values are offered as defaults.");

my %set;
my $network_name = prompt_value(
    'Network name',
    cfg('connection.CONN_SERVER_NETWORK', 0) || 'Undernet',
    qr/\A[^\r\n\x00]{1,100}\z/,
);
my $id_network = ensure_network($network_name);
$set{'connection.CONN_SERVER_NETWORK'} = $network_name;

configure_server($id_network, $network_name);

$set{'connection.CONN_NICK'} = prompt_value(
    'Bot nick', cfg('connection.CONN_NICK', 0) || 'mediabot', qr/\A\S{1,64}\z/
);
$set{'connection.CONN_USERNAME'} = prompt_value(
    'Bot ident (username)', cfg('connection.CONN_USERNAME', 0) || ($ENV{USER} // 'mediabot'), qr/\A\S{1,64}\z/
);
$set{'connection.CONN_IRCNAME'} = prompt_value(
    'Bot real name', cfg('connection.CONN_IRCNAME', 0) || 'mediabot', qr/\A[^\r\n\x00]{1,200}\z/
);
$set{'connection.CONN_PASS'} = prompt_secret_or_existing(
    'IRC server password (Enter keeps the current value; type - to clear)',
    cfg('connection.CONN_PASS', 0),
);
$set{'connection.CONN_BIND_IP'} = prompt_value_allow_empty(
    'Local bind IP (Enter keeps/defaults to empty; type - to clear)',
    cfg('connection.CONN_BIND_IP', 0),
    qr/\A[A-Za-z0-9_.:%-]*\z/,
);
$set{'connection.CONN_USERMODE'} = prompt_value(
    'Bot user mode', cfg('connection.CONN_USERMODE', 0) || '+i', qr/\A[^\r\n\x00]{1,64}\z/
);

log_messageln('Network types: 0=Other, 1=Undernet (X), 2=Libera/NickServ');
my $network_type = prompt_value(
    'Network type', cfg('connection.CONN_NETWORK_TYPE', 0) // 0, qr/\A[012]\z/
);
$set{'connection.CONN_NETWORK_TYPE'} = $network_type;

if ($network_type == 1) {
    log_messageln('Configuring the Undernet service section. Secrets are never written to the log.');
    $set{'undernet.UNET_CSERVICE_LOGIN'} = prompt_value(
        'Channel service target', cfg('undernet.UNET_CSERVICE_LOGIN', 0) || 'x@channels.undernet.org', qr/\A\S{1,200}\z/
    );
    $set{'undernet.UNET_CSERVICE_USERNAME'} = prompt_value_allow_empty(
        'Channel service username (Enter keeps current; type - to clear)', cfg('undernet.UNET_CSERVICE_USERNAME', 0), qr/\A[^\r\n\x00]*\z/
    );
    $set{'undernet.UNET_CSERVICE_PASSWORD'} = prompt_secret_or_existing(
        'Channel service password (Enter keeps current; type - to clear)', cfg('undernet.UNET_CSERVICE_PASSWORD', 0)
    );
}
elsif ($network_type == 2) {
    log_messageln('Configuring the Libera/NickServ service section. Secrets are never written to the log.');
    $set{'libera.LIBERA_NICKSERV_PASSWORD'} = prompt_secret_or_existing(
        'NickServ password (Enter keeps current; type - to clear)', cfg('libera.LIBERA_NICKSERV_PASSWORD', 0)
    );
}

addConsoleChannelCheck();
write_overlay_and_merge(\%set);

log_messageln("IRC/network configuration updated atomically in $CONFIG_FILE");
$dbh->disconnect if $dbh;
close $LOG;
exit 0;

sub usage {
    return "Usage: install/configure.pl --conf=/absolute/path/to/mediabot.conf\n";
}

sub now_stamp { return strftime('[%d/%m/%Y %H:%M:%S]', localtime); }
sub log_messageln {
    my ($msg) = @_;
    return unless defined $msg && length $msg;
    my $line = now_stamp() . " $msg\n";
    print $line;
    print {$LOG} $line;
}
sub log_message {
    my ($msg) = @_;
    return unless defined $msg && length $msg;
    my $line = now_stamp() . " $msg";
    print $line;
    print {$LOG} $line;
}

sub parse_ini {
    my ($file) = @_;
    open my $fh, '<', $file or die "Cannot read $file: $!\n";
    my (%v, $section);
    $section = '';
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/\r\z//;
        next if $line =~ /^\s*(?:[#;]|\z)/;
        if ($line =~ /^\s*\[([^\]]+)\]\s*\z/) {
            $section = lc trim($1);
            next;
        }
        next unless length $section && $line =~ /^\s*([^=]+?)\s*=\s*(.*)\z/s;
        my ($k, $value) = (trim($1), $2);
        $v{"$section.$k"} = $value;
    }
    close $fh;
    return \%v;
}

sub cfg {
    my ($key, $required) = @_;
    if ($required && (!exists $cfg->{$key} || !length $cfg->{$key})) {
        die "Required configuration key missing: $key\n";
    }
    return $cfg->{$key};
}

sub resolve_driver {
    my %available = map { $_ => 1 } DBI->available_drivers(0);
    return 'mysql' if $available{mysql};
    return 'MariaDB' if $available{MariaDB};
    die "Neither DBD::mysql nor DBD::MariaDB is installed\n";
}

sub dbConnect {
    my ($dbname, $host, $port, $user, $password) = @_;
    my $driver = resolve_driver();
    my @dsn = ("DBI:$driver:database=$dbname");
    $host = 'localhost' unless defined $host && length $host;
    push @dsn, "host=$host";
    push @dsn, "port=$port" unless $driver eq 'MariaDB' && $host eq 'localhost';

    my $dbh = DBI->connect(join(';', @dsn), $user, $password, {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    });
    $dbh->do('SET NAMES utf8mb4');
    return $dbh;
}

sub prompt_value {
    my ($label, $default, $validator) = @_;
    while (1) {
        log_message("$label [$default]: ");
        my $line = <STDIN>;
        die "Input closed while reading $label\n" unless defined $line;
        chomp $line;
        $line = $default if $line eq '';
        if ($line =~ $validator) {
            print {$LOG} "[value accepted]\n";
            return $line;
        }
        log_messageln('Invalid value, please try again.');
    }
}

sub prompt_value_allow_empty {
    my ($label, $current, $validator) = @_;
    $current //= '';
    while (1) {
        my $shown = length($current) ? $current : '<empty>';
        log_message("$label [$shown]: ");
        my $line = <STDIN>;
        die "Input closed while reading $label\n" unless defined $line;
        chomp $line;
        $line = $current if $line eq '';
        $line = '' if $line eq '-';
        if ($line =~ $validator) {
            print {$LOG} "[value accepted]\n";
            return $line;
        }
        log_messageln('Invalid value, please try again.');
    }
}

sub prompt_secret_or_existing {
    my ($label, $current) = @_;
    $current //= '';
    my $state = length($current) ? 'current value set' : 'currently empty';
    log_message("$label [$state]: ");
    system('stty', '-echo') == 0 or die "Cannot disable terminal echo\n";
    my $line = <STDIN>;
    system('stty', 'echo') == 0 or die "Cannot restore terminal echo\n";
    print "\n";
    print {$LOG} "[secret input hidden]\n";
    die "Input closed while reading secret\n" unless defined $line;
    chomp $line;
    return $current if $line eq '';
    return '' if $line eq '-';
    die "Invalid control character in secret\n" if $line =~ /[\x00\r\n]/;
    return $line;
}

sub ensure_network {
    my ($network_name) = @_;
    my $sth = $dbh->prepare('SELECT id_network, network_name FROM NETWORK WHERE network_name = ?');
    $sth->execute($network_name);
    if (my $row = $sth->fetchrow_hashref) {
        log_messageln("Network '$row->{network_name}' already exists (id $row->{id_network}).");
        return $row->{id_network};
    }

    $sth = $dbh->prepare('INSERT INTO NETWORK (network_name) VALUES (?)');
    $sth->execute($network_name);
    my $id = $sth->{Database}->last_insert_id(undef, undef, undef, undef);
    log_messageln("Network '$network_name' added (id $id).");
    return $id;
}

sub configure_server {
    my ($id_network, $network_name) = @_;
    my $sth = $dbh->prepare('SELECT server_hostname FROM SERVERS WHERE id_network = ? ORDER BY id_server');
    $sth->execute($id_network);
    my @servers;
    while (my ($host) = $sth->fetchrow_array) {
        push @servers, $host;
    }
    log_messageln("Existing server: $_") for @servers;

    my $default = @servers ? $servers[0] : '';
    my $label = @servers
        ? 'IRC server hostname (Enter keeps the first existing server; type a new host to add it)'
        : 'IRC server hostname';
    my $host = prompt_value($label, $default || 'irc.example.net', qr/\A[A-Za-z0-9_.:-]{1,255}\z/);
    return if grep { lc($_) eq lc($host) } @servers;
    addIrcServer($id_network, $host);
}

sub addIrcServer {
    my ($id_network, $server_hostname) = @_;
    my $sQuery = 'INSERT INTO SERVERS (id_network,server_hostname) VALUES (?,?)';
    my $sth = $dbh->prepare($sQuery);
    $sth->execute($id_network, $server_hostname);
    my $id_server = $sth->{Database}->last_insert_id(undef, undef, undef, undef);
    log_messageln("IRC Server $server_hostname added in SERVERS table with id : $id_server");
    return $id_server;
}

sub addConsoleChannelCheck {
    my $sth = $dbh->prepare("SELECT id_channel, name FROM CHANNEL WHERE description='console' ORDER BY id_channel LIMIT 1");
    $sth->execute();
    if (my $row = $sth->fetchrow_hashref) {
        my $answer = prompt_value(
            "Console channel '$row->{name}' already exists. Keep it? (y/n)",
            'y', qr/\A[ynYN]\z/
        );
        return if lc($answer) eq 'y';
        my $delete = $dbh->prepare('DELETE FROM CHANNEL WHERE id_channel = ?');
        $delete->execute($row->{id_channel});
        log_messageln("Console channel '$row->{name}' removed.");
    }
    addConsoleChannel();
}

sub addConsoleChannel {
    my $channel = prompt_value('Default console channel', '#mediabot', qr/\A#[^\s,\x00\r\n]{1,100}\z/);
    my $key = prompt_value_allow_empty('Console channel key (Enter for none; type - to clear)', '', qr/\A[^\x00\r\n\s]*\z/);
    my $modes = '+stn';
    $modes .= "k $key" if length $key;

    if (length $key) {
        my $sth = $dbh->prepare('INSERT INTO CHANNEL (name,description,`key`,chanmode,auto_join) VALUES (?,?,?,?,1)');
        $sth->execute($channel, 'console', $key, $modes);
    }
    else {
        my $sth = $dbh->prepare('INSERT INTO CHANNEL (name,description,chanmode,auto_join) VALUES (?,?,?,1)');
        $sth->execute($channel, 'console', $modes);
    }
    log_messageln("Console channel '$channel' created.");
}

sub write_overlay_and_merge {
    my ($set) = @_;
    my ($fh, $overlay) = tempfile('mediabot_config_overlay_XXXX', TMPDIR => 1, UNLINK => 0);
    chmod 0600, $overlay or die "Cannot chmod $overlay: $!\n";
    for my $key (sort keys %$set) {
        my $value = defined $set->{$key} ? $set->{$key} : '';
        die "Unsafe newline/NUL in $key\n" if $value =~ /[\x00\r\n]/;
        print {$fh} "$key=$value\n";
    }
    close $fh or die "Cannot close $overlay: $!\n";

    my @cmd = (
        $^X, $CONFIG_HELPER,
        '--sample', File::Spec->catfile($APP_DIR, 'mediabot.sample.conf'),
        '--config', $CONFIG_FILE,
        '--mode', 'merge',
        '--overlay', $overlay,
        '--backup-dir', File::Spec->catdir(dirname($CONFIG_FILE), 'config-backups'),
    );
    my $rc = system @cmd;
    unlink $overlay;
    die "Configuration merge failed\n" if $rc != 0;
}

sub trim {
    my ($s) = @_;
    $s //= '';
    $s =~ s/^\s+|\s+$//g;
    return $s;
}
