package Mediabot::DB;

use strict;
use warnings;
use DBI;
use Time::HiRes ();

# CHARSET_MODE:
#   utf8mb4 (défaut) -> SET NAMES utf8mb4, etc.
#   latin1           -> SET NAMES latin1 (compat héritage)
#   off              -> ne touche pas au charset/collation de session

sub new {
    my ($class, $conf, $logger) = @_;
    my $self = {
        conf   => $conf,
        logger => $logger,
        dbh    => undef,
    };
    bless $self, $class;

    my $dbname = $conf->get('mysql.MAIN_PROG_DDBNAME') || '';
    my $dbhost = $conf->get('mysql.MAIN_PROG_DBHOST')  || 'localhost';
    my $dbuser = $conf->get('mysql.MAIN_PROG_DBUSER')  || '';
    my $dbpass = $conf->get('mysql.MAIN_PROG_DBPASS')  || '';
    my $dbport = $conf->get('mysql.MAIN_PROG_DBPORT')  || 3306;

    # Commutateur de compatibilité (configurable dans mediabot.conf)
    my $mode = lc($conf->get('mysql.CHARSET_MODE') // 'utf8mb4');   # utf8mb4 | latin1 | off
    $self->{charset_mode} = $mode;

    unless ($dbname && $dbuser) {
 $logger->log(0, " Missing DB configuration: DDBNAME or DBUSER is undefined.");
        $logger->log(0, "Check your [mysql] section in mediabot.conf");
        exit 1;
    }

    $logger->log(1, "Connecting to DB: $dbname at $dbhost:$dbport (charset_mode=$mode)");

    # DBD::MariaDB refuses port when host=localhost (uses Unix socket instead)
    # Force TCP by converting localhost to 127.0.0.1
    my $tcp_host = ($dbhost eq 'localhost') ? '127.0.0.1' : $dbhost;

    # mb548-B1: bound every network wait. Without these, a silently dropped
    # idle connection (NAT/conntrack/wait_timeout) can stall the FIRST db
    # access after quiet hours for tens of seconds — observed as "the first
    # command lags, the next ones are fine". Configurable, sane defaults.
    my $t_connect = _bounded_timeout($conf->get('mysql.CONNECT_TIMEOUT'), 5, 1, 60);
    my $t_read    = _bounded_timeout($conf->get('mysql.READ_TIMEOUT'),   30, 5, 300);
    my $t_write   = _bounded_timeout($conf->get('mysql.WRITE_TIMEOUT'),  30, 5, 300);

    my $dsn = "DBI:MariaDB:database=$dbname;host=$tcp_host;port=$dbport"
        . ";mariadb_connect_timeout=$t_connect"
        . ";mariadb_read_timeout=$t_read"
        . ";mariadb_write_timeout=$t_write";

    my %attrs = (
        RaiseError           => 0,
        PrintError           => 0,
        AutoCommit           => 1,
        mariadb_auto_reconnect => 1,
        # Active seulement en mode utf8mb4 (sinon on laisse à 0)
    );

    my $dbh = DBI->connect($dsn, $dbuser, $dbpass, \%attrs);
    if (!$dbh) {
 $logger->log(0, " DBI connect failed: " . $DBI::errstr);
        $logger->log(0, "Check your credentials in mediabot.conf");
        $logger->log(0, "Aborting startup.");
        exit 1;
    }

    # Appliquer le charset/collation de session selon le mode choisi
    _apply_session_charset($dbh, $logger, $mode);

    # Log de vérif (collation de session)
    eval {
        my $sth = $dbh->prepare("SHOW VARIABLES LIKE 'collation_connection'");
        if ($sth->execute) {
            my (undef, $value) = $sth->fetchrow_array;
            $logger->log(3, "  DB collation in use: $value");
        }
        $sth->finish;
        1;
    } or do {
        $logger->log(1, "Warn: couldn't read collation_connection ($@)");
    };

    $self->{dbh} = $dbh;
    $logger->log(3, " DBI connection successful");

    return $self;
}

sub _apply_session_charset {
    my ($dbh, $logger, $mode) = @_;

    my @sql;
    if ($mode eq 'utf8mb4') {
        @sql = (
            'SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci',
            'SET CHARACTER SET utf8mb4',                       # ⚠️ sans apostrophe orpheline
            'SET COLLATION_CONNECTION = utf8mb4_unicode_ci',
        );
    }
    elsif ($mode eq 'latin1') {  # compat héritage si des hashes ont été faits en latin1
        @sql = (
            'SET NAMES latin1',
            'SET CHARACTER SET latin1',
            'SET COLLATION_CONNECTION = latin1_swedish_ci',
        );
    }
    elsif ($mode eq 'off') {
        # Ne change rien — garder la session telle quelle
        $logger->log(2, "Charset mode OFF: leaving session charset/collation untouched");
        return;
    } else {
        # Valeur inattendue -> fallback utf8mb4
        $logger->log(0, "Unknown CHARSET_MODE '$mode', falling back to utf8mb4 -- check [mysql] in mediabot.conf");
        @sql = (
            'SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci',
            'SET CHARACTER SET utf8mb4',
            'SET COLLATION_CONNECTION = utf8mb4_unicode_ci',
        );
    }

    foreach my $stmt (@sql) {
        my $sth = $dbh->prepare($stmt);
        unless ($sth && $sth->execute) {
            $logger->log(1, "SQL error during init: $DBI::errstr (query: $stmt)");
        }
        $sth->finish if $sth;
    }
}

# Reconnexion (même signature que l'implémentation précédente si tu l'appelais)
sub _connect {
    my ($self) = @_;
    my $conf   = $self->{conf};
    my $logger = $self->{logger};

    my $dbname = $conf->get('mysql.MAIN_PROG_DDBNAME') || '';
    my $dbhost = $conf->get('mysql.MAIN_PROG_DBHOST')  || 'localhost';
    my $dbuser = $conf->get('mysql.MAIN_PROG_DBUSER')  || '';
    my $dbpass = $conf->get('mysql.MAIN_PROG_DBPASS')  || '';
    my $dbport = $conf->get('mysql.MAIN_PROG_DBPORT')  || 3306;
    my $mode   = $self->{charset_mode} // 'utf8mb4';

    # DBD::MariaDB refuses port when host=localhost (uses Unix socket instead)
    # Force TCP by converting localhost to 127.0.0.1
    my $tcp_host = ($dbhost eq 'localhost') ? '127.0.0.1' : $dbhost;

    # mb548-B1: bound every network wait. Without these, a silently dropped
    # idle connection (NAT/conntrack/wait_timeout) can stall the FIRST db
    # access after quiet hours for tens of seconds — observed as "the first
    # command lags, the next ones are fine". Configurable, sane defaults.
    my $t_connect = _bounded_timeout($conf->get('mysql.CONNECT_TIMEOUT'), 5, 1, 60);
    my $t_read    = _bounded_timeout($conf->get('mysql.READ_TIMEOUT'),   30, 5, 300);
    my $t_write   = _bounded_timeout($conf->get('mysql.WRITE_TIMEOUT'),  30, 5, 300);

    my $dsn = "DBI:MariaDB:database=$dbname;host=$tcp_host;port=$dbport"
        . ";mariadb_connect_timeout=$t_connect"
        . ";mariadb_read_timeout=$t_read"
        . ";mariadb_write_timeout=$t_write";
    my %attrs = (
        RaiseError           => 0,
        PrintError           => 0,
        AutoCommit           => 1,
        mariadb_auto_reconnect => 1,
    );

    $logger->log(1, "Connecting to DB: $dbname at $dbhost:$dbport (charset_mode=$mode)");
    my $dbh = DBI->connect($dsn, $dbuser, $dbpass, \%attrs);
    unless ($dbh) {
        # mb549-B1: a failed reconnect must not leave the old dead handle
        # looking usable to ensure_connected or legacy callers.
        $self->{dbh} = undef;
        $logger->log(0, "DBI connect failed: $DBI::errstr");
        return;
    }

    _apply_session_charset($dbh, $logger, $mode);
    $self->{dbh} = $dbh;
    return $dbh;
}

# mb559-B1: create a DB handle dedicated to a forked worker. This method
# never mutates the parent wrapper's canonical handle and never exits. The
# caller must ensure that any inherited parent DBI handle is marked
# InactiveDestroy in the child before using this new connection.
sub connect_isolated_handle {
    my ($self) = @_;
    my $conf = $self->{conf};
    return (undef, 'missing database configuration')
        unless $conf && eval { $conf->can('get') };

    my $dbname = $conf->get('mysql.MAIN_PROG_DDBNAME') || '';
    my $dbhost = $conf->get('mysql.MAIN_PROG_DBHOST')  || 'localhost';
    my $dbuser = $conf->get('mysql.MAIN_PROG_DBUSER')  || '';
    my $dbpass = $conf->get('mysql.MAIN_PROG_DBPASS')  || '';
    my $dbport = $conf->get('mysql.MAIN_PROG_DBPORT')  || 3306;
    my $mode   = $self->{charset_mode} // 'utf8mb4';
    return (undef, 'missing database name or user') unless $dbname && $dbuser;

    my $tcp_host = ($dbhost eq 'localhost') ? '127.0.0.1' : $dbhost;
    my $t_connect = _bounded_timeout($conf->get('mysql.CONNECT_TIMEOUT'), 5, 1, 60);
    my $t_read    = _bounded_timeout($conf->get('mysql.READ_TIMEOUT'),   30, 5, 300);
    my $t_write   = _bounded_timeout($conf->get('mysql.WRITE_TIMEOUT'),  30, 5, 300);

    my $dsn = "DBI:MariaDB:database=$dbname;host=$tcp_host;port=$dbport"
        . ";mariadb_connect_timeout=$t_connect"
        . ";mariadb_read_timeout=$t_read"
        . ";mariadb_write_timeout=$t_write";
    my %attrs = (
        RaiseError             => 0,
        PrintError             => 0,
        AutoCommit             => 1,
        mariadb_auto_reconnect => 0,
    );

    my $dbh = DBI->connect($dsn, $dbuser, $dbpass, \%attrs);
    return (undef, ($DBI::errstr || 'isolated DB connect failed')) unless $dbh;

    my @sql;
    if ($mode eq 'latin1') {
        @sql = (
            'SET NAMES latin1',
            'SET CHARACTER SET latin1',
            'SET COLLATION_CONNECTION = latin1_swedish_ci',
        );
    }
    elsif ($mode ne 'off') {
        @sql = (
            'SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci',
            'SET CHARACTER SET utf8mb4',
            'SET COLLATION_CONNECTION = utf8mb4_unicode_ci',
        );
    }

    for my $stmt (@sql) {
        my $ok = eval {
            my $sth = $dbh->prepare($stmt);
            my $rv = $sth && $sth->execute;
            $sth->finish if $sth;
            $rv ? 1 : 0;
        };
        unless ($ok) {
            my $err = $@ || $DBI::errstr || 'session charset setup failed';
            eval { $dbh->disconnect };
            $err =~ s/[\r\n\0]+/ /g;
            return (undef, substr($err, 0, 240));
        }
    }

    return ($dbh, undef);
}

sub dbh {
    my ($self) = @_;
    return $self->{dbh};
}

# mb550-B1: optional Prometheus projection, injected after construction.
# Strictly best-effort: without it, health behavior is unchanged.
sub set_metrics {
    my ($self, $metrics) = @_;
    $self->{metrics} = $metrics;
    $self->_health_metric('set', 'mediabot_db_up', ($self->{dbh} ? 1 : 0));
    return 1;
}

sub _health_metric {
    my ($self, $method, @args) = @_;
    my $metrics = $self->{metrics};
    return 0 unless $metrics && eval { $metrics->can($method) };
    eval { $metrics->$method(@args); 1 } or return 0;
    return 1;
}

# mb548-B1: bounded numeric timeout with default (0 or garbage -> default).
sub _bounded_timeout {
    my ($raw, $default, $min, $max) = @_;
    return $default unless defined $raw && !ref($raw) && "$raw" =~ /\A[0-9]+\z/;
    my $v = int($raw);
    return $default if $v == 0;
    $v = $min if $v < $min;
    $v = $max if $v > $max;
    return $v;
}

# ensure_connected() — verify DB handle is alive, reconnect if needed
# Call this before any critical DB operation in long-running event loops
# mb548-B1: every path is TIMED — a slow ping (dying socket) and a reconnect
# both log their duration, so a laggy first command after idle hours shows
# its cause in the log instead of staying a mystery.
sub ensure_connected {
    my ($self) = @_;
    my $dbh = $self->{dbh};

    my $t0 = [ Time::HiRes::gettimeofday() ];
    my $alive = $dbh && eval { $dbh->ping };
    my $ping_s = Time::HiRes::tv_interval($t0);

    if ($alive) {
        if ($ping_s > 0.25) {
            $self->{logger}->log(3, sprintf('DB ping slow: %.2fs (connection degrading?)', $ping_s))
                if $self->{logger};
            $self->_health_metric('inc', 'mediabot_db_slow_pings_total');
        }
        $self->_health_metric('set', 'mediabot_db_up', 1);
        return $dbh;
    }

    $self->{logger}->log(1, 'DB connection lost, reconnecting...') if $self->{logger};
    my $t1 = [ Time::HiRes::gettimeofday() ];

    # mb549-B1: discard the known-dead handle before reconnecting. Otherwise a
    # dying _connect can leave a truthy stale object behind and produce a false
    # "DB reconnect ok" line while returning an unusable handle.
    $self->{dbh} = undef;
    my $new_dbh;
    my $connect_eval_ok = eval {
        $new_dbh = $self->_connect;
        1;
    };
    my $reconnect_ok = $connect_eval_ok && $new_dbh ? 1 : 0;
    $self->{dbh} = undef unless $reconnect_ok;

    my $reconnect_s = Time::HiRes::tv_interval($t1);
    # mb550-B1: reconnects and availability become Prometheus series.
    $self->_health_metric('inc', 'mediabot_db_reconnects_total',
        { result => ($reconnect_ok ? 'ok' : 'failed') });
    $self->_health_metric('set', 'mediabot_db_up', ($reconnect_ok ? 1 : 0));
    if ($self->{logger}) {
        my $state = $reconnect_ok ? 'ok' : 'FAILED';
        $self->{logger}->log(1, sprintf('DB reconnect %s in %.2fs (ping wait was %.2fs)',
            $state, $reconnect_s, $ping_s));
    }
    return $reconnect_ok ? $new_dbh : undef;
}

1;
