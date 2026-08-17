#!/usr/bin/env perl
# =============================================================================
# tools/mediabot_doctor.pl — diagnostic STRICTEMENT EN LECTURE d'une instance
# =============================================================================
# ROUND 1 : noyau + modele de faits + sondes filesystem / config / runtime.
# ROUND 2 : systemd + updater/deploiement.
# ROUND 3 : database + migrations, toujours strictement read-only. La base
# est ouverte par le chemin non fatal connect_isolated_handle(), puis la
# session est forcee READ ONLY avant toute requete Doctor. Le schema drift
# reste delegue a l'outil de reference au lieu d'etre reimplemente ici.
#
# CE QUE CET OUTIL NE FAIT JAMAIS :
#   - ecrire, creer, supprimer ou deplacer quoi que ce soit ;
#   - modifier une base ou un schema ;
#   - lancer le bot, le tuer, ou lui envoyer un signal ;
#   - imprimer la VALEUR d'un secret (elle n'entre meme pas dans le modele) ;
#   - faire echouer ce qu'il diagnostique.
#
# Cette derniere ligne n'est pas une precaution de style. En mb643 j'ai passe
# au pilote MariaDB un attribut qu'il ne connaissait pas en supposant qu'il
# serait ignore : DBI l'a REFUSE, la connexion a echoue, et le demarrage s'est
# termine par exit 1 — le bot ne demarrait plus du tout. Un outil de
# diagnostic doit tenir la meme regle en plus strict que le code qu'il
# examine.
#
# ROUND 3 : ne JAMAIS appeler Mediabot::DB->new() ici — ce constructeur peut
# exit(1). Doctor construit un wrapper minimal uniquement pour reutiliser
# connect_isolated_handle(), qui retourne une erreur sans tuer le processus.
# Les secrets restent confines a l'objet de conf lexical de la sonde et
# n'entrent jamais dans le contexte partage ni dans les faits/JSON.
# =============================================================================

use strict;
use warnings;
use utf8;

use File::Basename qw(basename dirname);
use File::Spec;
use Cwd qw(abs_path);
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);
use IPC::Open3 qw(open3);
use IO::Select;
use Symbol qw(gensym);
use Time::HiRes qw(time sleep);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

our $VERSION = '1.1';

# Version du MODELE de faits, pas de l'outil. Un consommateur JSON doit
# pouvoir refuser un modele qu'il ne comprend pas plutot que de deviner.
use constant SCHEMA_VERSION => 1;

# -----------------------------------------------------------------------------
# 1. Le modele de faits — fige pour les SEPT domaines
# -----------------------------------------------------------------------------
# Les sept domaines existent des le round 1, meme non implementes : leur
# absence est elle-meme un fait (status => 'not_implemented'), et le
# consommateur JSON connait donc la forme finale immediatement.
our @DOMAINS = qw(runtime systemd config database updater filesystem migrations);
our %DOMAIN_SET = map { $_ => 1 } @DOMAINS;

our %DOMAIN_ROUND = (
    runtime    => 1, config     => 1, filesystem => 1,
    systemd    => 2, updater    => 2,
    database   => 3, migrations => 3,
);

# Niveaux, du plus calme au plus grave. UNKNOWN n'est PAS un niveau de
# gravite : c'est l'aveu qu'un fait n'a pas pu etre etabli. Il ne doit jamais
# devenir un OK par defaut ni un FAIL alarmiste — en mb640, un eval nu
# transformait un plantage en « version could not be determined », rendant
# panne reseau et bug de code indiscernables.
our @LEVELS = qw(ok info unknown warn fail);
our %LEVEL_RANK = do { my $i = 0; map { $_ => $i++ } @LEVELS };

# Un FAIT est une structure plate et close :
#   domain   : l'un de @DOMAINS
#   id       : identifiant stable, machine-lisible (jamais traduit)
#   level    : l'un de @LEVELS
#   summary  : une ligne pour un humain
#   detail   : precision facultative
#   source   : PROVENANCE — d'ou vient ce fait. Obligatoire : un diagnostic
#              sans provenance n'est pas verifiable.
#   data     : donnees structurees, JAMAIS de secret (voir _fact ci-dessous)
sub _fact {
    my (%f) = @_;

    my %allowed = map { $_ => 1 } qw(domain id level summary detail source data);
    for my $key (keys %f) {
        die "fact: unknown field '$key'\n" unless $allowed{$key};
    }

    for my $key (qw(domain id level summary source)) {
        die "fact: missing $key\n"
            unless defined $f{$key} && !ref($f{$key}) && length($f{$key});
    }

    die "fact: unknown domain '$f{domain}'\n" unless $DOMAIN_SET{$f{domain}};
    die "fact: unknown level '$f{level}'\n"   unless exists $LEVEL_RANK{$f{level}};
    die "fact: invalid id '$f{id}'\n"
        unless $f{id} =~ /\A[a-z0-9][a-z0-9_.-]*\z/i;
    die "fact: detail must be scalar\n"
        if exists $f{detail} && defined $f{detail} && ref($f{detail});
    die "fact: data must be a hash reference\n"
        if exists $f{data} && ref($f{data}) ne 'HASH';

    return {
        domain  => $f{domain},
        id      => $f{id},
        level   => $f{level},
        summary => $f{summary},
        (defined $f{detail} && length $f{detail} ? (detail => $f{detail}) : ()),
        source  => $f{source},
        data    => (exists $f{data} ? $f{data} : {}),
    };
}

# -----------------------------------------------------------------------------
# 2. Secrets — ils n'entrent PAS dans le modele
# -----------------------------------------------------------------------------
# Masquer au rendu ne suffit pas : le modele de faits part en JSON, peut etre
# copie dans un ticket, un pastebin ou un canal. Un secret ne doit donc jamais
# y figurer, meme masque. On ne conserve que present => 1|0.
our @SECRET_PATTERNS = qw(PASS PASSWORD TOKEN SECRET API_KEY APIKEY CLIENT_SECRET
                          PRIVATE_KEY CREDENTIAL AUTH_KEY);

sub is_secret_key {
    my ($key) = @_;
    return 0 unless defined $key;
    my $k = uc $key;
    for my $p (@SECRET_PATTERNS) {
        return 1 if index($k, $p) >= 0;
    }
    return 0;
}

# -----------------------------------------------------------------------------
# 3. Interface commune des sondes — figee au round 1
# -----------------------------------------------------------------------------
# Une sonde est une structure :
#   domain    : le domaine qu'elle renseigne
#   round     : round d'implementation
#   collect   : coderef($ctx) -> liste de faits BRUTS, sans verdict
#   evaluate  : coderef($facts, $ctx) -> liste de faits EVALUES
#
# La separation collecte / evaluation n'est pas cosmetique : la collecte
# touche le monde reel (donc intestable en suite), l'evaluation est une
# fonction PURE de faits vers constats — et celle-la se teste integralement.
# C'est la discipline qui a fait ses preuves sur Mediabot::Update (mb631).
our %PROBES;

sub register_probe {
    my (%p) = @_;
    die "probe without domain\n" unless defined $p{domain} && length $p{domain};
    die "probe with unknown domain '$p{domain}'\n" unless $DOMAIN_SET{$p{domain}};
    die "probe '$p{domain}' without collect callback\n" unless ref($p{collect}) eq 'CODE';
    die "probe '$p{domain}' without evaluate callback\n" unless ref($p{evaluate}) eq 'CODE';
    $PROBES{ $p{domain} } = {
        domain   => $p{domain},
        round    => $p{round} // 1,
        collect  => $p{collect},
        evaluate => $p{evaluate},
    };
    return 1;
}

# Sonde non encore implementee : elle existe, elle le dit, et son domaine
# apparait dans la sortie. Un domaine silencieux serait indiscernable d'un
# domaine sain.
sub _declare_pending {
    my ($domain, $why) = @_;
    register_probe(
        domain  => $domain,
        round   => $DOMAIN_ROUND{$domain} // 2,
        collect => sub { return () },
        evaluate => sub {
            return _fact(
                domain  => $domain,
                id      => "$domain.not_implemented",
                level   => 'info',
                summary => "domain not implemented yet (round $DOMAIN_ROUND{$domain})",
                detail  => $why,
                source  => 'doctor',
                data    => { implemented => 0, round => $DOMAIN_ROUND{$domain} },
            );
        },
    );
}

# -----------------------------------------------------------------------------
# Helpers read-only partages par les sondes round 2
# -----------------------------------------------------------------------------
sub _find_executable {
    my ($name) = @_;
    return undef unless defined $name && length $name;
    for my $dir (File::Spec->path()) {
        next unless defined $dir && length $dir;
        my $p = File::Spec->catfile($dir, $name);
        return $p if -f $p && -x $p;
    }
    return undef;
}

sub _capture_command {
    my (@cmd) = @_;
    return { ok => 0, rc => 127, stdout => '', stderr => 'empty command' }
        unless @cmd;

    my ($in, $out);
    my $err = gensym();
    my $pid = eval { open3($in, $out, $err, @cmd) };
    if (!$pid) {
        my $why = $@ || $! || 'unable to execute command';
        $why =~ s/\s+\z//;
        return { ok => 0, rc => 127, stdout => '', stderr => "$why" };
    }
    close $in;
    local $/;
    my $stdout = <$out> // '';
    my $stderr = <$err> // '';
    close $out;
    close $err;
    waitpid($pid, 0);
    my $rc = $? == -1 ? 127 : ($? >> 8);
    return { ok => ($rc == 0 ? 1 : 0), rc => $rc,
             stdout => $stdout, stderr => $stderr };
}

sub _capture_command_bounded {
    my ($timeout, @cmd) = @_;
    $timeout = 20 unless defined $timeout && $timeout > 0;
    return { ok => 0, rc => 127, stdout => '', stderr => 'empty command' }
        unless @cmd;

    my ($in, $out);
    my $err = gensym();
    my $pid = eval { open3($in, $out, $err, @cmd) };
    if (!$pid) {
        my $why = $@ || $! || 'unable to execute command';
        $why =~ s/\s+\z//;
        return { ok => 0, rc => 127, stdout => '', stderr => "$why" };
    }
    close $in;

    my $sel = IO::Select->new($out, $err);
    my %kind = (fileno($out) => 'stdout', fileno($err) => 'stderr');
    my %buf = (stdout => '', stderr => '');
    my $max_bytes = 262_144;
    my $deadline = time() + $timeout;
    my $timed_out = 0;

    while ($sel->count) {
        my $left = $deadline - time();
        if ($left <= 0) { $timed_out = 1; last }
        my @ready = $sel->can_read($left > 0.25 ? 0.25 : $left);
        next unless @ready;
        for my $fh (@ready) {
            my $fd = fileno($fh);
            my $n = sysread($fh, my $chunk, 8192);
            if (!defined $n) {
                next if $!{EINTR};
                $sel->remove($fh); close $fh;
                next;
            }
            if ($n == 0) {
                $sel->remove($fh); close $fh;
                next;
            }
            my $k = $kind{$fd} // 'stdout';
            my $room = $max_bytes - length($buf{$k});
            $buf{$k} .= substr($chunk, 0, $room) if $room > 0;
        }
    }

    if ($timed_out) {
        kill 'TERM', $pid;
        sleep 0.15;
        kill 'KILL', $pid if kill(0, $pid);
        waitpid($pid, 0);
        for my $fh ($out, $err) { eval { close $fh } }
        return { ok => 0, rc => 124, timeout => 1,
                 stdout => $buf{stdout}, stderr => $buf{stderr} };
    }

    waitpid($pid, 0);
    my $status = $?;
    my $rc = $status == -1 ? 127 : ($status >> 8);
    return { ok => ($rc == 0 ? 1 : 0), rc => $rc,
             stdout => $buf{stdout}, stderr => $buf{stderr} };
}

sub _sanitize_diag_text {
    my ($text, $max) = @_;
    $text //= '';
    $max //= 500;
    $text =~ s/[\r\n\0]+/ /g;
    $text =~ s/\s+/ /g;
    $text =~ s/\b(pass(?:word)?|token|secret|api[_-]?key)\s*[:=]\s*\S+/$1=<redacted>/ig;
    $text =~ s/^\s+|\s+$//g;
    return substr($text, 0, $max);
}

sub _doctor_db_connect {
    my ($ctx) = @_;
    return (undef, { error => 'configuration file is missing or unreadable' })
        unless defined $ctx->{conf_file} && -f $ctx->{conf_file} && -r $ctx->{conf_file};

    my ($conf, $mode, $dbname, $dbuser, $dbhost, $dbport);
    my $loaded = eval {
        local @INC = ($ctx->{root}, @INC);
        require Mediabot::Conf;
        require Mediabot::DB;
        $conf = Mediabot::Conf->new(undef, $ctx->{conf_file});
        $mode   = lc($conf->get('mysql.CHARSET_MODE') // 'utf8mb4');
        $dbname = $conf->get('mysql.MAIN_PROG_DDBNAME') // '';
        $dbuser = $conf->get('mysql.MAIN_PROG_DBUSER') // '';
        $dbhost = $conf->get('mysql.MAIN_PROG_DBHOST') // 'localhost';
        $dbport = $conf->get('mysql.MAIN_PROG_DBPORT') // 3306;
        1;
    };
    unless ($loaded) {
        my $err = _sanitize_diag_text($@ || 'cannot load database configuration');
        return (undef, { error => $err });
    }

    # Deliberately bypass Mediabot::DB->new(): it can exit(1). The wrapper
    # contains only what connect_isolated_handle() needs. The password remains
    # lexical inside $conf and never enters shared context or facts/JSON.
    my $db_obj = bless { conf => $conf, charset_mode => $mode }, 'Mediabot::DB';
    my ($dbh, $err) = eval { $db_obj->connect_isolated_handle() };
    if (!$dbh) {
        my $why = _sanitize_diag_text($@ || $err || 'database connection failed');
        return (undef, { error => $why, dbname => $dbname, dbuser => $dbuser,
                         dbhost => $dbhost, dbport => $dbport, charset_mode => $mode });
    }

    # Enforce a session-level read-only policy before Doctor runs any query.
    # SET NAMES performed by connect_isolated_handle() only changes session
    # decoding; no persistent data or schema is modified.
    my $readonly_ok = eval { $dbh->do('SET SESSION TRANSACTION READ ONLY') };
    unless ($readonly_ok) {
        my $why = _sanitize_diag_text($@ || $DBI::errstr || 'cannot enforce read-only DB session');
        eval { $dbh->disconnect };
        return (undef, { error => "read-only session refused: $why",
                         dbname => $dbname, dbuser => $dbuser,
                         dbhost => $dbhost, dbport => $dbport, charset_mode => $mode });
    }

    my $driver = eval { $dbh->{Driver}{Name} } // '';
    my $driver_version = eval { $dbh->{Driver}{Version} } // '';
    return ($dbh, {
        dbname => $dbname, dbuser => $dbuser, dbhost => $dbhost, dbport => $dbport,
        charset_mode => $mode, driver => $driver, driver_version => $driver_version,
        read_only_enforced => 1,
    });
}

sub _db_select_one {
    my ($dbh, $sql, @bind) = @_;
    my $sth = eval { $dbh->prepare($sql) };
    return (undef, _sanitize_diag_text($@ || $DBI::errstr || 'prepare failed')) unless $sth;
    my $ok = eval { $sth->execute(@bind) };
    unless ($ok) {
        my $err = _sanitize_diag_text($@ || $DBI::errstr || 'execute failed');
        eval { $sth->finish };
        return (undef, $err);
    }
    my $row = $sth->fetchrow_hashref;
    $sth->finish;
    return ($row, undef);
}

sub _db_select_all {
    my ($dbh, $sql, @bind) = @_;
    my $sth = eval { $dbh->prepare($sql) };
    return (undef, _sanitize_diag_text($@ || $DBI::errstr || 'prepare failed')) unless $sth;
    my $ok = eval { $sth->execute(@bind) };
    unless ($ok) {
        my $err = _sanitize_diag_text($@ || $DBI::errstr || 'execute failed');
        eval { $sth->finish };
        return (undef, $err);
    }
    my $rows = $sth->fetchall_arrayref({});
    $sth->finish;
    return ($rows, undef);
}

sub _migration_sql_without_comments {
    my ($text) = @_;
    $text //= '';
    $text =~ s{/\*.*?\*/}{}gs;
    my @lines = grep { $_ !~ /^\s*--/ && $_ !~ /^\s*#/ } split /\n/, $text;
    return join("\n", @lines);
}

sub _matching_paren_body {
    my ($text, $open) = @_;
    my $depth = 0;
    my ($single, $double, $backtick) = (0, 0, 0);
    for (my $i = $open; $i < length($text); $i++) {
        my $c = substr($text, $i, 1);
        my $prev = $i ? substr($text, $i - 1, 1) : '';
        if (!$double && !$backtick && $c eq "'" && $prev ne '\\') { $single = !$single; next }
        if (!$single && !$backtick && $c eq '"' && $prev ne '\\') { $double = !$double; next }
        if (!$single && !$double && $c eq '`') { $backtick = !$backtick; next }
        next if $single || $double || $backtick;
        if ($c eq '(') { $depth++ }
        elsif ($c eq ')') {
            $depth--;
            return (substr($text, $open + 1, $i - $open - 1), $i) if $depth == 0;
        }
    }
    return (undef, undef);
}

sub _migration_observables {
    my ($path) = @_;
    return { effects => [], reason => 'migration file missing' }
        unless defined $path && -f $path && !-l $path;
    open my $fh, '<:raw', $path or return { effects => [], reason => "cannot read migration: $!" };
    local $/;
    my $raw = <$fh> // '';
    close $fh;
    my $sql = _migration_sql_without_comments($raw);
    my @effects;
    my %seen;
    my $add = sub {
        my ($type, %e) = @_;
        my $key = join('|', $type, map { defined $e{$_} ? $e{$_} : '' }
                                   qw(table column index constraint chanset));
        return if $seen{$key}++;
        push @effects, { type => $type, %e };
    };

    # CREATE TABLE: observe the table plus its declared columns/indexes/FKs.
    while ($sql =~ /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?`?([A-Za-z0-9_]+)`?\s*\(/ig) {
        my $table = $1;
        my $open = pos($sql) - 1;
        my ($body, $end) = _matching_paren_body($sql, $open);
        last unless defined $body;
        $add->('table', table => $table);
        while ($body =~ /^\s*`([A-Za-z0-9_]+)`\s+/mg) {
            $add->('column', table => $table, column => $1);
        }
        if ($body =~ /\bPRIMARY\s+KEY\b/i) {
            $add->('index', table => $table, index => 'PRIMARY');
        }
        while ($body =~ /\b(?:UNIQUE\s+)?(?:KEY|INDEX)\s+`?([A-Za-z0-9_]+)`?/ig) {
            $add->('index', table => $table, index => $1);
        }
        while ($body =~ /\bCONSTRAINT\s+`?([A-Za-z0-9_]+)`?\s+FOREIGN\s+KEY/ig) {
            $add->('constraint', table => $table, constraint => $1);
        }
        pos($sql) = $end + 1;
    }

    # ALTER TABLE effects, including statements embedded in dynamic SQL strings.
    while ($sql =~ /ALTER\s+TABLE\s+`?([A-Za-z0-9_]+)`?\s+ADD\s+COLUMN\s+`?([A-Za-z0-9_]+)`?/ig) {
        $add->('column', table => $1, column => $2);
    }
    while ($sql =~ /ALTER\s+TABLE\s+`?([A-Za-z0-9_]+)`?[\s\S]{0,180}?\bADD\s+(?:UNIQUE\s+)?(?:INDEX|KEY)\s+`?([A-Za-z0-9_]+)`?/ig) {
        $add->('index', table => $1, index => $2);
    }
    while ($sql =~ /ALTER\s+TABLE\s+`?([A-Za-z0-9_]+)`?[\s\S]{0,180}?\bADD\s+CONSTRAINT\s+`?([A-Za-z0-9_]+)`?\s+FOREIGN\s+KEY/ig) {
        $add->('constraint', table => $1, constraint => $2);
    }

    # Data-only migrations currently use CHANSET_LIST. Capture the inserted
    # semantic value, never the historical fact "this file was executed".
    while ($sql =~ /(INSERT(?:\s+IGNORE)?\s+INTO\s+`?CHANSET_LIST`?[\s\S]*?;)/ig) {
        my $stmt = $1;
        while ($stmt =~ /'([^']+)'/g) {
            my $v = $1;
            next if $v =~ /\s/ || $v =~ /already|exists/i;
            $add->('chanset', chanset => $v) if $v =~ /\A[A-Za-z][A-Za-z0-9_]*\z/;
        }
    }

    # Unsupported mutation forms make historical inference indeterminate even
    # if some other durable effects were recognised.
    my $unsupported = 0;
    $unsupported = 1 if $sql =~ /^\s*(?:UPDATE|DELETE\s+FROM|REPLACE\s+INTO)\b/im;
    $unsupported = 1 if $sql =~ /^\s*INSERT\s+(?:IGNORE\s+)?INTO\s+(?!`?CHANSET_LIST`?)/im;

    return {
        effects => \@effects,
        unsupported_mutation => $unsupported,
        reason => (!@effects ? 'no durable observable effect recognised' : undef),
    };
}

sub _status_has_75 {
    my ($value) = @_;
    return 0 unless defined $value;
    return 1 if $value =~ /(?:^|\s)75(?:\s|$)/;
    return 1 if $value =~ /(?:^|\s)TEMPFAIL(?:\s|$)/i; # sysexits.h EX_TEMPFAIL = 75
    return 0;
}

sub _service_unit_from_cgroup_text {
    my ($text) = @_;
    return undef unless defined $text;
    for my $line (split /\n/, $text) {
        my ($path) = $line =~ /\A\d*:[^:]*:(.*)\z/;
        next unless defined $path;
        my @parts = grep { length } split m{/+}, $path;
        for my $part (reverse @parts) {
            return $part if $part =~ /\A[A-Za-z0-9_.@\\:-]+\.service\z/;
        }
    }
    return undef;
}

sub _group_snapshot {
    my ($gid) = @_;
    return {} unless defined $gid;

    my ($group_name, $members);
    my @gr = getgrgid($gid);
    if (@gr) {
        $group_name = $gr[0];
        $members = $gr[3] // '';
    }
    my @supp = grep { length } split /\s+/, ($members // '');

    my @primary;
    setpwent();
    while (my @pw = getpwent()) {
        push @primary, $pw[0] if defined $pw[3] && $pw[3] == $gid;
    }
    endpwent();

    return {
        group_name    => $group_name,
        primary_users => \@primary,
        members       => \@supp,
    };
}

sub _private_runtime_group {
    my ($entry, $ctx) = @_;
    return undef unless defined $ctx->{expected_uid};
    return undef unless defined $entry->{gid};
    return undef unless ref($entry->{group_snapshot}) eq 'HASH';

    my $runtime_user = getpwuid($ctx->{expected_uid});
    return undef unless defined $runtime_user && length $runtime_user;

    my @primary = @{ $entry->{group_snapshot}{primary_users} // [] };
    my @members = @{ $entry->{group_snapshot}{members} // [] };
    my %people = map { $_ => 1 } grep { defined && length } (@primary, @members);
    delete $people{$runtime_user};

    return 0 if keys %people;
    return 0 unless grep { $_ eq $runtime_user } @primary;
    return 1;
}

sub _scan_deployment_family {
    my ($root) = @_;
    my $parent = dirname($root);
    my $base   = basename($root);
    my (@archives, @ignored);

    opendir(my $dh, $parent) or return {
        ok => 0, family => $base, parent => $parent,
        archives => [], ignored_sibling_families => [], error => "$!",
    };
    while (my $name = readdir($dh)) {
        next if $name eq '.' || $name eq '..' || $name eq $base;
        my $path = File::Spec->catfile($parent, $name);
        next unless -d $path;
        next if -l $path;

        if ($name =~ /\A\Q$base\E(?:\.\d+|\.old\.\d{8}_\d{6})\z/) {
            push @archives, $name;
            next;
        }
        if ($name =~ /\Amediabot[^\/]*(?:\.\d+|\.old\.\d{8}_\d{6})\z/i) {
            push @ignored, $name;
        }
    }
    closedir $dh;
    return {
        ok => 1, family => $base, parent => $parent,
        archives => [ sort @archives ],
        ignored_sibling_families => [ sort @ignored ],
    };
}

# =============================================================================
# SONDE : filesystem
# =============================================================================

sub _identity_access {
    my ($entry, $ctx, $want) = @_;
    return undef unless defined $ctx->{expected_uid};
    return undef unless defined $entry->{uid} && defined $entry->{gid}
                     && defined $entry->{mode};

    my $mode = oct($entry->{mode});
    my $uid  = $ctx->{expected_uid};
    my %gids = map { $_ => 1 } @{ $ctx->{expected_gids} // [] };

    # uid 0 can read/write any ordinary object, but execution still requires
    # an execute bit (or a directory traversal bit) to avoid reporting a
    # non-executable script as runnable.
    if ($uid == 0) {
        return 1 if $want eq 'read' || $want eq 'write';
        return (($mode & 0111) ? 1 : 0) if $want eq 'exec';
    }

    my $shift = ($uid == $entry->{uid}) ? 6 : ($gids{$entry->{gid}} ? 3 : 0);
    my $bits  = ($mode >> $shift) & 07;
    return ($bits & 04) ? 1 : 0 if $want eq 'read';
    return ($bits & 02) ? 1 : 0 if $want eq 'write';
    return ($bits & 01) ? 1 : 0 if $want eq 'exec';
    return undef;
}

{
    my $snapshot = sub {
        my (%a) = @_;
        my $path = $a{path};

        my @lst = lstat($path);
        my $is_symlink = @lst && -l _ ? 1 : 0;
        my $target = $is_symlink ? readlink($path) : undef;

        my @st = stat($path); # follows a healthy symlink
        my $exists = @st ? 1 : 0;

        my %snap = (
            %a,
            path           => $path,
            exists         => $exists,
            lstat_exists   => (@lst ? 1 : 0),
            is_symlink     => $is_symlink,
            symlink_target => $target,
            broken_symlink => ($is_symlink && !$exists ? 1 : 0),
            is_dir         => ($exists && -d _ ? 1 : 0),
            size           => ($exists ? $st[7] : undef),
            uid            => ($exists ? $st[4] : undef),
            gid            => ($exists ? $st[5] : undef),
            mode           => ($exists ? sprintf('%04o', $st[2] & 07777) : undef),
            observer_readable => ($exists && -r $path ? 1 : 0),
            observer_writable => ($exists && -w $path ? 1 : 0),
            observer_executable => ($exists && -x $path ? 1 : 0),
        );
        $snap{group_snapshot} = _group_snapshot($snap{gid})
            if $exists && $a{config};
        return \%snap;
    };

    my $collect = sub {
        my ($ctx) = @_;
        my @raw;

        # Core paths that define a usable Mediabot tree.
        push @raw, $snapshot->(
            id => 'main_program',
            path => File::Spec->catfile($ctx->{root}, 'mediabot.pl'),
            kind => 'file', required => 1, executable => 1,
            source => 'derived:root/mediabot.pl',
        );
        push @raw, $snapshot->(
            id => 'version_file',
            path => File::Spec->catfile($ctx->{root}, 'VERSION'),
            kind => 'file', required => 1,
            source => 'derived:root/VERSION',
        );
        push @raw, $snapshot->(
            id => 'module_dir',
            path => File::Spec->catdir($ctx->{root}, 'Mediabot'),
            kind => 'dir', required => 1,
            source => 'derived:root/Mediabot',
        );
        push @raw, $snapshot->(
            id => 'sample_conf',
            path => $ctx->{sample_conf},
            kind => 'file', required => 1,
            source => 'derived:mediabot.sample.conf',
        );

        # The inspected instance may legitimately be an unconfigured source
        # tree. Missing config is therefore observable, but not a broken tree.
        push @raw, $snapshot->(
            id => 'config_file', path => $ctx->{conf_file}, kind => 'file',
            config => 1, source => 'cli/default config path',
        );

        # Paths controlled by the instance configuration.
        my @targets = (
            { id => 'pid_file',     key => 'main.MAIN_PID_FILE',     kind => 'file' },
            { id => 'log_file',     key => 'main.MAIN_LOG_FILE',     kind => 'file', writable => 1 },
            { id => 'achievements', key => 'main.ACHIEVEMENTS_PATH', kind => 'file',
              default => 'var/achievements.json' },
            { id => 'plugin_data',  key => 'plugins.DATA_DIR',       kind => 'dir',
              default => 'plugin-data', writable => 1 },
        );

        for my $t (@targets) {
            my $path = $ctx->{conf_values}{ $t->{key} };
            $path = $t->{default} unless defined $path && length $path;
            next unless defined $path;
            $path = File::Spec->rel2abs($path, $ctx->{root})
                unless File::Spec->file_name_is_absolute($path);
            push @raw, $snapshot->(%$t, path => $path, source => "conf:$t->{key}");
        }

        # Project directory and its parent. Parent writeability matters to the
        # built-in updater when it rotates release trees.
        push @raw, $snapshot->(
            id => 'project_dir', path => $ctx->{root}, kind => 'dir',
            required => 1, source => 'cli/default root',
        );
        push @raw, $snapshot->(
            id => 'parent_dir', path => dirname($ctx->{root}), kind => 'dir',
            writable => 1, source => 'derived:parent(root)',
        );

        return @raw;
    };

    my $evaluate = sub {
        my ($raw, $ctx) = @_;
        my @out;

        for my $e (@$raw) {
            my $id = "filesystem.$e->{id}";
            my $source = $e->{source}
                // ($e->{key} ? "conf:$e->{key}" : 'derived');

            if ($e->{broken_symlink}) {
                push @out, _fact(
                    domain => 'filesystem', id => $id,
                    level => ($e->{required} ? 'fail' : 'warn'),
                    summary => "$e->{id} is a broken symlink",
                    detail => defined $e->{symlink_target}
                        ? "target: $e->{symlink_target}" : undef,
                    source => $source,
                    data => {
                        path => $e->{path}, exists => 0, symlink => 1,
                        target => $e->{symlink_target},
                    },
                );
                next;
            }

            # achievements.json is legacy state after mb646. Its absence is
            # normal until the database probe can prove JSON fallback is active.
            if ($e->{id} eq 'achievements' && !$e->{exists}) {
                push @out, _fact(
                    domain => 'filesystem', id => $id, level => 'info',
                    summary => 'legacy achievements JSON absent',
                    detail  => 'storage relevance is evaluated by the database domain; '
                             . 'absence alone is not a filesystem error.',
                    source  => $source,
                    data    => { path => $e->{path}, exists => 0, legacy_fallback => 'unknown' },
                );
                next;
            }

            unless ($e->{exists}) {
                my $level = $e->{required} ? 'fail' : 'info';
                my $summary = $e->{required}
                    ? "$e->{id} is required but missing"
                    : "$e->{id} does not exist yet";
                push @out, _fact(
                    domain => 'filesystem', id => $id, level => $level,
                    summary => $summary, source => $source,
                    data => { path => $e->{path}, exists => 0 },
                );
                next;
            }

            my $level = 'ok';
            my @notes;

            if ($e->{kind} eq 'dir' && !$e->{is_dir}) {
                $level = 'fail';
                push @notes, 'expected a directory';
            }
            if ($e->{kind} eq 'file' && $e->{is_dir}) {
                $level = 'fail';
                push @notes, 'expected a file';
            }

            # Executability depends on HOW the live instance launches the script.
            # `/usr/bin/perl mediabot.pl` requires read permission, not +x.
            # Direct execution requires +x.  If no live invocation is observable,
            # missing +x remains a packaging warning rather than a false runtime FAIL.
            my $missing_exec_bit = $e->{executable} && !(oct($e->{mode}) & 0111);
            if ($missing_exec_bit) {
                if (($ctx->{main_program_invocation_mode} // '') eq 'direct') {
                    $level = 'fail';
                    push @notes, 'no executable bit is set but the running instance executes mediabot.pl directly';
                }
                elsif (($ctx->{main_program_invocation_mode} // '') eq 'perl') {
                    $level = _worse($level, 'warn');
                    push @notes, 'no executable bit is set; current runtime is safe because mediabot.pl is launched through perl';
                }
                else {
                    $level = _worse($level, 'warn');
                    push @notes, 'no executable bit is set; direct execution would fail';
                }
            }

            my $runtime_read  = _identity_access($e, $ctx, 'read');
            my $runtime_write = _identity_access($e, $ctx, 'write');
            my $runtime_exec  = _identity_access($e, $ctx, 'exec');

            if (defined $runtime_read && !$runtime_read) {
                $level = _worse($level, 'fail');
                push @notes, 'not readable by the observed runtime identity';
            }
            if ($e->{writable} && defined $runtime_write && !$runtime_write) {
                $level = _worse($level, 'warn');
                push @notes, 'not writable by the observed runtime identity';
            }
            if ($e->{executable} && defined $runtime_exec && !$runtime_exec
                && ($ctx->{main_program_invocation_mode} // '') eq 'direct') {
                $level = _worse($level, 'fail');
                push @notes, 'not executable by the observed runtime identity';
            }

            # Config files contain credentials, but 0660/0640 on a PRIVATE
            # service group is not equivalent to world/group exposure.  Judge
            # the actual group membership instead of worshipping 0600 as a
            # magic number.  World bits remain a real warning.
            my @info_notes;
            if ($e->{config}) {
                my $mode = oct($e->{mode});
                if ($mode & 0007) {
                    $level = _worse($level, 'warn');
                    push @notes, "configuration permissions $e->{mode} expose access to other users";
                }
                elsif ($mode & 0070) {
                    my $private = _private_runtime_group($e, $ctx);
                    if (defined $private && $private) {
                        my $g = $e->{group_snapshot}{group_name} // $e->{gid};
                        push @info_notes, "configuration permissions $e->{mode} use private runtime group $g";
                    }
                    else {
                        $level = _worse($level, 'warn');
                        push @notes, defined($private)
                            ? "configuration group permissions $e->{mode} are accessible beyond the runtime user"
                            : "configuration group permissions $e->{mode} could not be proven private";
                    }
                }
            }

            if (defined $ctx->{expected_uid} && defined $e->{uid}
                && $e->{uid} != $ctx->{expected_uid}
                && !$e->{config}) {
                $level = _worse($level, 'warn');
                push @notes, "owned by uid $e->{uid}, expected $ctx->{expected_uid}"
                           . " (from $ctx->{expected_uid_source})";
            }

            push @out, _fact(
                domain => 'filesystem', id => $id, level => $level,
                summary => ($level eq 'ok'
                    ? "$e->{id} present and usable"
                    : "$e->{id}: " . join('; ', @notes)),
                detail => do {
                    my @detail = @info_notes;
                    push @detail, "symlink target: $e->{symlink_target}"
                        if $e->{is_symlink} && defined $e->{symlink_target};
                    @detail ? join('; ', @detail) : undef;
                },
                source => $source,
                data => {
                    path => $e->{path}, exists => 1, mode => $e->{mode},
                    uid => $e->{uid}, gid => $e->{gid},
                    symlink => $e->{is_symlink} ? 1 : 0,
                    (defined $e->{symlink_target} ? (target => $e->{symlink_target}) : ()),
                    (defined $e->{size} ? (size => $e->{size}) : ()),
                    observer_access => {
                        read => $e->{observer_readable},
                        write => $e->{observer_writable},
                        exec => $e->{observer_executable},
                    },
                    runtime_access => {
                        read => $runtime_read,
                        write => $runtime_write,
                        exec => $runtime_exec,
                    },
                },
            );
        }

        return @out;
    };

    register_probe(domain => 'filesystem', round => 1,
                   collect => $collect, evaluate => $evaluate);
}

# =============================================================================
# SONDE : config
# =============================================================================
{
    # Trois ensembles, donc trois ecarts possibles :
    #   - clef lue par le code   (litteraux get('section.KEY'))
    #   - clef documentee        (mediabot.sample.conf)
    #   - clef definie           (le mediabot.conf de l'instance)
    # Le test 615 couvre deja le premier ecart EN CI ; seul Doctor voit le
    # troisieme, sur une instance reelle — et c'est le plus utile.
    my $collect = sub {
        my ($ctx) = @_;

        my %read_by_code;
        for my $file (@{ $ctx->{source_files} }) {
            open my $fh, '<:raw', $file or next;
            while (my $line = <$fh>) {
                next if $line =~ /^\s*#/;
                while ($line =~ /get(?:_int)?\('([a-z_]+\.[A-Z_0-9]+)'/g) {
                    $read_by_code{$1}++;
                }
                # get_int(...) porte souvent un defaut explicite : la clef est
                # alors « defaulted », pas « required ».
                while ($line =~ /get_int\('([a-z_]+\.[A-Z_0-9]+)'[^)]*default\s*=>/g) {
                    $ctx->{_defaulted}{$1} = 1;
                }
            }
            close $fh;
        }

        my %documented;
        if (open my $fh, '<:raw', $ctx->{sample_conf}) {
            my $section = '';
            while (my $line = <$fh>) {
                $section = $1 if $line =~ /^\[([a-z_]+)\]/;
                if ($line =~ /^#?([A-Z_0-9]+)=/ && $section ne '') {
                    $documented{"$section.$1"} = 1;
                }
            }
            close $fh;
        }

        my %defined_in_conf;
        my $conf_readable = 0;
        if (open my $fh, '<:raw', $ctx->{conf_file}) {
            $conf_readable = 1;
            my $section = '';
            while (my $line = <$fh>) {
                next if $line =~ /^\s*[#;]/;
                $section = $1 if $line =~ /^\s*\[([a-z_]+)\]/;
                if ($line =~ /^\s*([A-Z_0-9]+)\s*=\s*(.*?)\s*$/ && $section ne '') {
                    my ($k, $v) = ("$section.$1", $2);
                    $v =~ s/\A["']//; $v =~ s/["']\z//;
                    # LE SECRET N'ENTRE PAS DANS LE MODELE : on ne garde que
                    # sa presence. Masquer au rendu serait insuffisant, le
                    # modele part en JSON et peut etre recopie n'importe ou.
                    $defined_in_conf{$k} = is_secret_key($1)
                        ? { present => 1, secret => 1 }
                        : { present => 1, secret => 0, value => $v };
                }
            }
            close $fh;
        }

        return {
            read_by_code    => \%read_by_code,
            documented      => \%documented,
            defined_in_conf => \%defined_in_conf,
            conf_readable   => $conf_readable,
            defaulted       => ($ctx->{_defaulted} // {}),
        };
    };

    my $evaluate = sub {
        my ($raw, $ctx) = @_;
        my @out;

        # Aucun source analyse : sans clefs « lues par le code », tout
        # paraitrait sain. C'est un UNKNOWN, pas un OK — la regle §2.2 vaut
        # aussi contre les faux negatifs, pas seulement contre les alarmes.
        unless (%{ $raw->{read_by_code} }) {
            return _fact(
                domain => 'config', id => 'config.no_sources', level => 'unknown',
                summary => 'no Perl source found: configuration cannot be cross-checked',
                detail  => "looked under $ctx->{root}",
                source  => 'code scan',
                data    => { root => $ctx->{root} },
            );
        }

        unless ($raw->{conf_readable}) {
            return _fact(
                domain => 'config', id => 'config.unreadable', level => 'unknown',
                summary => 'configuration file could not be read',
                detail  => "path: $ctx->{conf_file}",
                source  => 'filesystem',
                data    => { path => $ctx->{conf_file} },
            );
        }

        # Classement d'une clef lue mais absente de la conf. Une clef absente
        # n'est PAS automatiquement un probleme : beaucoup ont un defaut dans
        # le code, d'autres n'arment qu'une fonction optionnelle.
        #   required  : le bot ne peut pas fonctionner sans (connexion, base)
        #   defaulted : le code fournit une valeur de repli
        #   optional  : arme une fonction facultative
        # Source de verite : Mediabot::DB->new() rend DDBNAME + DBUSER
        # fatals. DBHOST/DBPORT/DBPASS ont des valeurs de repli, et les clefs
        # de connexion IRC sont validees ailleurs selon le reseau choisi.
        my %required = map { $_ => 1 } qw(
            mysql.MAIN_PROG_DDBNAME
            mysql.MAIN_PROG_DBUSER
        );

        my @missing_required;
        my @missing_optional;
        for my $key (sort keys %{ $raw->{read_by_code} }) {
            next if exists $raw->{defined_in_conf}{$key};
            if ($required{$key})                    { push @missing_required, $key }
            elsif ($raw->{defaulted}{$key})         { next }   # le code a un repli
            else                                    { push @missing_optional, $key }
        }

        push @out, _fact(
            domain => 'config', id => 'config.required_keys',
            level  => (@missing_required ? 'fail' : 'ok'),
            summary => (@missing_required
                ? scalar(@missing_required) . ' required key(s) missing from the configuration'
                : 'all required keys are present'),
            detail  => (@missing_required ? join(', ', @missing_required) : undef),
            source  => "conf:$ctx->{conf_file}",
            data    => { missing => \@missing_required },
        );

        push @out, _fact(
            domain => 'config', id => 'config.optional_keys',
            level  => (@missing_optional ? 'info' : 'ok'),
            summary => (@missing_optional
                ? scalar(@missing_optional) . ' optional key(s) not set (feature disabled)'
                : 'no optional key missing'),
            detail  => (@missing_optional
                ? join(', ', @missing_optional[0 .. ($#missing_optional > 11 ? 11 : $#missing_optional)])
                  . ($#missing_optional > 11 ? ', ...' : '')
                : undef),
            source  => "conf:$ctx->{conf_file}",
            data    => { missing => \@missing_optional },
        );

        # Clef definie mais jamais lue : heritage mort, ou faute de frappe.
        my @orphans = grep { !exists $raw->{read_by_code}{$_} }
                      sort keys %{ $raw->{defined_in_conf} };
        push @out, _fact(
            domain => 'config', id => 'config.unused_keys',
            level  => (@orphans ? 'info' : 'ok'),
            summary => (@orphans
                ? scalar(@orphans) . ' key(s) set but never read by the code'
                : 'every configured key is read by the code'),
            detail  => (@orphans ? join(', ', @orphans[0 .. ($#orphans > 9 ? 9 : $#orphans)])
                                   . ($#orphans > 9 ? ', ...' : '')
                                 : undef),
            source  => 'code scan + conf',
            data    => { keys => \@orphans },
        );

        # Clef lue mais absente du sample : le test 615 le verifie en CI. Ici
        # c'est un simple rappel — la CI reste la source de verite.
        my @undocumented = grep { !$raw->{documented}{$_} }
                           sort keys %{ $raw->{read_by_code} };
        push @out, _fact(
            domain => 'config', id => 'config.undocumented_keys',
            level  => (@undocumented ? 'warn' : 'ok'),
            summary => (@undocumented
                ? scalar(@undocumented) . ' key(s) read by the code but absent from the sample'
                : 'every key read by the code is documented in the sample'),
            detail  => (@undocumented ? join(', ', @undocumented) : undef),
            source  => 'code scan + mediabot.sample.conf',
            data    => { keys => \@undocumented },
        );

        # Secrets : on rapporte leur PRESENCE, jamais leur valeur.
        my @secrets = sort grep { $raw->{defined_in_conf}{$_}{secret} }
                      keys %{ $raw->{defined_in_conf} };
        push @out, _fact(
            domain => 'config', id => 'config.secrets',
            level  => 'info',
            summary => scalar(@secrets) . ' secret key(s) present (values never collected)',
            source  => "conf:$ctx->{conf_file}",
            data    => { keys => \@secrets, values_collected => 0 },
        );

        return @out;
    };

    register_probe(domain => 'config', round => 1,
                   collect => $collect, evaluate => $evaluate);
}

# =============================================================================
# SONDE : runtime
# =============================================================================

sub _normalize_path {
    my ($path, $base) = @_;
    return undef unless defined $path && length $path;
    my $p = File::Spec->file_name_is_absolute($path)
        ? File::Spec->canonpath($path)
        : File::Spec->rel2abs($path, $base);
    my $real = eval { abs_path($p) };
    return defined($real) ? $real : File::Spec->canonpath($p);
}


sub _mediabot_invocation_mode {
    my ($argv, $expected_exec, $cwd) = @_;
    return ('unknown', undef) unless ref($argv) eq 'ARRAY' && @$argv;

    my $script_index;
    for (my $i = 0; $i < @$argv; $i++) {
        my $arg = $argv->[$i];
        next unless defined $arg && $arg =~ /mediabot\.pl\z/;
        my $candidate = _normalize_path($arg, $cwd);
        if (defined $candidate && defined $expected_exec && $candidate eq $expected_exec) {
            $script_index = $i;
            last;
        }
    }
    return ('unknown', undef) unless defined $script_index;

    # argv[0] == mediabot.pl means direct execution (shebang + executable bit).
    return ('direct', $argv->[0]) if $script_index == 0;

    # The production units intentionally invoke /usr/bin/perl "$BOT_BIN".
    # In that mode the script must be readable, but the kernel never executes
    # mediabot.pl itself, so a missing +x is packaging drift rather than a
    # runtime failure. Keep the interpreter for an auditable explanation.
    my $launcher = $argv->[0];
    if (defined $launcher && $launcher =~ m{(?:^|/)perl(?:[0-9.]+)?\z}) {
        return ('perl', $launcher);
    }

    return ('indirect', $launcher);
}
sub _conf_from_argv {
    my ($argv, $cwd) = @_;
    return undef unless ref($argv) eq 'ARRAY';
    for (my $i = 0; $i < @$argv; $i++) {
        my $arg = $argv->[$i];
        next unless defined $arg;
        if ($arg =~ /\A--conf=(.*)\z/s) {
            return _normalize_path($1, $cwd);
        }
        if ($arg eq '--conf' && $i + 1 < @$argv) {
            return _normalize_path($argv->[$i + 1], $cwd);
        }
    }
    return undef;
}

{
    my $collect = sub {
        my ($ctx) = @_;
        my %r = (
            pid_file => $ctx->{conf_values}{'main.MAIN_PID_FILE'},
            root_exists => (-d $ctx->{root} ? 1 : 0),
            root_has_main => (-f File::Spec->catfile($ctx->{root}, 'mediabot.pl') ? 1 : 0),
        );

        if (defined $r{pid_file} && length $r{pid_file}) {
            $r{pid_file} = File::Spec->rel2abs($r{pid_file}, $ctx->{root})
                unless File::Spec->file_name_is_absolute($r{pid_file});
            if (open my $fh, '<', $r{pid_file}) {
                my $line = <$fh>;
                close $fh;
                $r{pid_file_readable} = 1;
                if (defined $line && $line =~ /\A\s*(\d+)\s*\z/) { $r{pid} = int($1) }
                else { $r{pid_malformed} = 1 }
            }
            else { $r{pid_file_readable} = 0 }
        }

        if (defined $r{pid}) {
            # kill 0 checks existence/permission without delivering a signal.
            $r{alive} = (kill(0, $r{pid}) ? 1 : 0);
            if (!$r{alive} && $!{EPERM}) {
                $r{alive} = 1;
                $r{foreign_owner} = 1;
            }

            my $cwd_link = "/proc/$r{pid}/cwd";
            my $cwd = readlink($cwd_link);
            $r{proc_cwd} = $cwd if defined $cwd;

            my $cmd = "/proc/$r{pid}/cmdline";
            if (open my $fh, '<:raw', $cmd) {
                local $/;
                my $bytes = <$fh>;
                close $fh;
                if (defined $bytes) {
                    my @argv = split /\0/, $bytes, -1;
                    pop @argv while @argv && $argv[-1] eq '';
                    $r{argv} = \@argv;
                    $r{cmdline} = join(' ', @argv);
                }
            }

            if (open my $fh, '<', "/proc/$r{pid}/status") {
                while (my $line = <$fh>) {
                    if ($line =~ /^Groups:\s*(.*?)\s*$/) {
                        my @g = grep { /\A\d+\z/ } split /\s+/, $1;
                        $r{proc_groups} = [ map { int($_) } @g ];
                        last;
                    }
                }
                close $fh;
            }

            if (my @st = stat("/proc/$r{pid}")) {
                $r{proc_uid} = $st[4];
                $r{proc_gid} = $st[5];
                $r{started}  = $st[10];
            }
        }

        if (open my $fh, '<', File::Spec->catfile($ctx->{root}, 'VERSION')) {
            my $v = <$fh>;
            close $fh;
            if (defined $v) { $v =~ s/\s+\z//; $r{tree_version} = $v }
        }

        return \%r;
    };

    my $evaluate = sub {
        my ($raw, $ctx) = @_;
        my @out;

        if (!$raw->{root_exists}) {
            push @out, _fact(
                domain => 'runtime', id => 'runtime.root', level => 'fail',
                summary => 'project root does not exist',
                detail => $ctx->{root}, source => 'cli/default root',
                data => { root => $ctx->{root}, exists => 0, mediabot_tree => 0 },
            );
        }
        elsif (!$raw->{root_has_main}) {
            push @out, _fact(
                domain => 'runtime', id => 'runtime.root', level => 'fail',
                summary => 'project root is not a Mediabot tree',
                detail => 'mediabot.pl is missing',
                source => 'cli/default root',
                data => { root => $ctx->{root}, exists => 1, mediabot_tree => 0 },
            );
        }
        else {
            push @out, _fact(
                domain => 'runtime', id => 'runtime.root', level => 'ok',
                summary => 'project root looks like a Mediabot tree',
                source => 'cli/default root',
                data => { root => $ctx->{root}, exists => 1, mediabot_tree => 1 },
            );
        }

        push @out, _fact(
            domain => 'runtime', id => 'runtime.tree_version',
            level  => (defined $raw->{tree_version} ? 'ok' : 'warn'),
            summary => (defined $raw->{tree_version}
                ? "tree version $raw->{tree_version}"
                : 'VERSION file missing or unreadable'),
            source  => 'file:VERSION',
            data    => { version => $raw->{tree_version} },
        );

        unless (defined $raw->{pid_file}) {
            return (@out, _fact(
                domain => 'runtime', id => 'runtime.pid_file', level => 'unknown',
                summary => 'no PID file configured (main.MAIN_PID_FILE)',
                source => 'conf:main.MAIN_PID_FILE', data => {},
            ));
        }

        unless ($raw->{pid_file_readable}) {
            return (@out, _fact(
                domain => 'runtime', id => 'runtime.state', level => 'info',
                summary => 'no PID file: the bot does not appear to be running',
                detail => "expected at $raw->{pid_file}",
                source => 'conf:main.MAIN_PID_FILE',
                data => { pid_file => $raw->{pid_file}, running => 0 },
            ));
        }

        if ($raw->{pid_malformed}) {
            return (@out, _fact(
                domain => 'runtime', id => 'runtime.pid_file', level => 'warn',
                summary => 'PID file exists but does not contain a PID',
                source => "file:$raw->{pid_file}",
                data => { pid_file => $raw->{pid_file} },
            ));
        }

        unless ($raw->{alive}) {
            push @out, _fact(
                domain => 'runtime', id => 'runtime.state', level => 'warn',
                summary => "stale PID file: process $raw->{pid} is not running",
                detail => 'The bot stopped without removing its PID file.',
                source => "file:$raw->{pid_file}",
                data => { pid => $raw->{pid}, running => 0, stale_pid_file => 1 },
            );
            return @out;
        }

        my $expected_exec = _normalize_path(
            File::Spec->catfile($ctx->{root}, 'mediabot.pl'), $ctx->{root});
        my $cwd = $raw->{proc_cwd} // $ctx->{root};

        my $exec_match;
        my ($invocation_mode, $launcher) = ('unknown', undef);
        if (ref($raw->{argv}) eq 'ARRAY') {
            $exec_match = 0;
            for my $arg (@{ $raw->{argv} }) {
                next unless defined $arg && $arg =~ /mediabot\.pl\z/;
                my $candidate = _normalize_path($arg, $cwd);
                if (defined $candidate && defined $expected_exec
                    && $candidate eq $expected_exec) {
                    $exec_match = 1;
                    last;
                }
            }
            ($invocation_mode, $launcher) =
                _mediabot_invocation_mode($raw->{argv}, $expected_exec, $cwd)
                    if $exec_match;
        }

        if (!defined $exec_match) {
            push @out, _fact(
                domain => 'runtime', id => 'runtime.state', level => 'unknown',
                summary => "process $raw->{pid} is alive but its argv could not be read",
                detail => 'Cannot confirm it is this Mediabot tree.',
                source => "/proc/$raw->{pid}/cmdline",
                data => { pid => $raw->{pid}, running => 1, executable_confirmed => 0 },
            );
        }
        elsif (!$exec_match) {
            push @out, _fact(
                domain => 'runtime', id => 'runtime.state', level => 'fail',
                summary => "PID $raw->{pid} belongs to a different process/tree",
                detail => "expected executable $expected_exec",
                source => "/proc/$raw->{pid}/cmdline",
                data => { pid => $raw->{pid}, running => 1,
                          executable_confirmed => 0, recycled_pid => 1 },
            );
        }
        else {
            push @out, _fact(
                domain => 'runtime', id => 'runtime.state', level => 'ok',
                summary => "Mediabot is running (pid $raw->{pid})"
                         . (defined $raw->{started}
                            ? ', started ' . strftime('%Y-%m-%d %H:%M:%S', localtime($raw->{started}))
                            : ''),
                source => "file:$raw->{pid_file} + /proc",
                data => { pid => $raw->{pid}, running => 1,
                          executable_confirmed => 1, started => $raw->{started},
                          invocation_mode => $invocation_mode, launcher => $launcher },
            );
        }

        # The tree and the config are independent identity dimensions. A PID
        # can legitimately run the right mediabot.pl with the wrong instance
        # configuration, so expose that mismatch separately.
        if ($exec_match) {
            my $expected_conf = _normalize_path($ctx->{conf_file}, $ctx->{root});
            my $actual_conf = _conf_from_argv($raw->{argv}, $cwd);
            if (!defined $actual_conf) {
                push @out, _fact(
                    domain => 'runtime', id => 'runtime.config_identity',
                    level => 'fail',
                    summary => 'running Mediabot has no --conf argument',
                    detail => "expected $expected_conf",
                    source => "/proc/$raw->{pid}/cmdline",
                    data => { expected_conf => $expected_conf, actual_conf => undef,
                              config_confirmed => 0 },
                );
            }
            elsif ($actual_conf ne $expected_conf) {
                push @out, _fact(
                    domain => 'runtime', id => 'runtime.config_identity',
                    level => 'fail',
                    summary => 'running Mediabot uses a different configuration',
                    detail => "expected $expected_conf; actual $actual_conf",
                    source => "/proc/$raw->{pid}/cmdline",
                    data => { expected_conf => $expected_conf, actual_conf => $actual_conf,
                              config_confirmed => 0 },
                );
            }
            else {
                push @out, _fact(
                    domain => 'runtime', id => 'runtime.config_identity',
                    level => 'ok',
                    summary => 'running Mediabot uses the inspected configuration',
                    source => "/proc/$raw->{pid}/cmdline",
                    data => { expected_conf => $expected_conf, actual_conf => $actual_conf,
                              config_confirmed => 1 },
                );
            }
        }

        if (defined $raw->{proc_uid}) {
            my $name = getpwuid($raw->{proc_uid});
            my @groups = @{ $raw->{proc_groups} // [] };
            if (defined $raw->{proc_gid} && !grep { $_ == $raw->{proc_gid} } @groups) {
                push @groups, $raw->{proc_gid};
            }
            push @out, _fact(
                domain => 'runtime', id => 'runtime.process_owner', level => 'info',
                summary => 'running as uid ' . $raw->{proc_uid}
                         . (defined $name ? " ($name)" : ''),
                source => "/proc/$raw->{pid}",
                data => { uid => $raw->{proc_uid}, gid => $raw->{proc_gid},
                          gids => \@groups, user => $name },
            );
        }

        return @out;
    };

    register_probe(domain => 'runtime', round => 1,
                   collect => $collect, evaluate => $evaluate);
}

# =============================================================================
# Domaines declares, implementes plus tard
# =============================================================================
# =============================================================================
# SONDE : systemd (round 2)
# =============================================================================
{
    my $collect = sub {
        my ($ctx) = @_;
        my %r = (pid => $ctx->{observed_pid});
        return \%r unless defined $r{pid};

        my $cgroup_path = "/proc/$r{pid}/cgroup";
        if (open my $fh, '<:raw', $cgroup_path) {
            local $/; my $text = <$fh>; close $fh;
            $r{cgroup_readable} = 1;
            $r{unit} = _service_unit_from_cgroup_text($text);
        }
        else { $r{cgroup_readable} = 0 }

        # Never collect the complete environment: it can contain API keys and
        # credentials. Read only the one non-secret contract marker we need.
        my $env_path = "/proc/$r{pid}/environ";
        if (open my $fh, '<:raw', $env_path) {
            local $/; my $bytes = <$fh>; close $fh;
            $r{environ_readable} = 1;
            my ($marker) = grep { /\AMEDIABOT_SYSTEMD_UPDATE_SAFE=/ }
                           split /\0/, ($bytes // '');
            if (defined $marker) {
                $r{marker_present} = 1;
                $marker =~ s/\AMEDIABOT_SYSTEMD_UPDATE_SAFE=//;
                $r{marker_safe} = ($marker eq '1' ? 1 : 0);
            }
            else {
                $r{marker_present} = 0;
                $r{marker_safe} = 0;
            }
        }
        else { $r{environ_readable} = 0 }

        if (defined $r{unit}) {
            my $systemctl = _find_executable('systemctl');
            $r{systemctl} = $systemctl;
            if (defined $systemctl) {
                my @props = qw(Id LoadState ActiveState SubState Restart ExitType
                               SuccessExitStatus RestartPreventExitStatus User Group FragmentPath);
                my $cmd = _capture_command(
                    $systemctl, 'show', '--no-pager',
                    '--property=' . join(',', @props), $r{unit});
                $r{systemctl_rc} = $cmd->{rc};
                $r{systemctl_error} = $cmd->{stderr} unless $cmd->{ok};
                if ($cmd->{ok}) {
                    my %p;
                    for my $line (split /\n/, $cmd->{stdout}) {
                        next unless $line =~ /\A([^=]+)=(.*)\z/;
                        $p{$1} = $2;
                    }
                    $r{properties} = \%p;
                }
            }
        }
        return \%r;
    };

    my $evaluate = sub {
        my ($raw, $ctx) = @_;
        my @out;

        unless (defined $raw->{pid}) {
            return _fact(
                domain => 'systemd', id => 'systemd.runtime_manager', level => 'info',
                summary => 'bot is not running; runtime manager is not observable',
                source => 'runtime probe', data => { managed => 'not_running' },
            );
        }

        if (!$raw->{cgroup_readable}) {
            push @out, _fact(
                domain => 'systemd', id => 'systemd.runtime_manager', level => 'unknown',
                summary => 'cannot read process cgroup; runtime manager is unknown',
                source => "/proc/$raw->{pid}/cgroup", data => { pid => $raw->{pid} },
            );
        }
        elsif (defined $raw->{unit}) {
            push @out, _fact(
                domain => 'systemd', id => 'systemd.runtime_manager', level => 'ok',
                summary => "runtime managed by systemd unit $raw->{unit}",
                source => "/proc/$raw->{pid}/cgroup",
                data => { pid => $raw->{pid}, manager => 'systemd', unit => $raw->{unit} },
            );
        }
        else {
            push @out, _fact(
                domain => 'systemd', id => 'systemd.runtime_manager', level => 'info',
                summary => 'running outside a systemd service',
                source => "/proc/$raw->{pid}/cgroup",
                data => { pid => $raw->{pid}, manager => 'manual' },
            );
        }

        if (!$raw->{environ_readable}) {
            push @out, _fact(
                domain => 'systemd', id => 'systemd.safe_update_marker', level => 'unknown',
                summary => 'cannot read the running process safe-update marker',
                source => "/proc/$raw->{pid}/environ", data => {},
            );
        }
        elsif ($raw->{marker_safe}) {
            push @out, _fact(
                domain => 'systemd', id => 'systemd.safe_update_marker', level => 'ok',
                summary => 'MB645 safe-update marker is active in the running process',
                source => "/proc/$raw->{pid}/environ",
                data => { present => 1, safe => 1 },
            );
        }
        elsif (defined $raw->{unit}) {
            my $updater_irrelevant = $ctx->{builtin_updater_intentionally_inapplicable} ? 1 : 0;
            push @out, _fact(
                domain => 'systemd', id => 'systemd.safe_update_marker',
                level => ($updater_irrelevant ? 'info' : 'warn'),
                summary => ($updater_irrelevant
                    ? 'MB645 safe-update marker is absent; built-in updater is not applicable to this deployment'
                    : 'systemd runtime does not advertise the MB645 safe-update marker'),
                source => "/proc/$raw->{pid}/environ",
                data => { present => ($raw->{marker_present} ? 1 : 0), safe => 0,
                          builtin_updater_applicable => ($updater_irrelevant ? 0 : undef) },
            );
        }
        else {
            push @out, _fact(
                domain => 'systemd', id => 'systemd.safe_update_marker', level => 'info',
                summary => 'safe-update marker absent outside systemd (normal)',
                source => "/proc/$raw->{pid}/environ",
                data => { present => ($raw->{marker_present} ? 1 : 0), safe => 0 },
            );
        }

        my $contract_state = 'not_applicable';
        if (defined $raw->{unit}) {
            if (!defined $raw->{systemctl}) {
                push @out, _fact(
                    domain => 'systemd', id => 'systemd.actual_contract', level => 'unknown',
                    summary => 'systemctl is unavailable; actual unit contract cannot be verified',
                    source => 'PATH:systemctl', data => { unit => $raw->{unit} },
                );
                $contract_state = 'unknown';
            }
            elsif (!defined $raw->{properties}) {
                push @out, _fact(
                    domain => 'systemd', id => 'systemd.actual_contract', level => 'unknown',
                    summary => "cannot inspect systemd unit $raw->{unit}",
                    detail => $raw->{systemctl_error}, source => 'systemctl show',
                    data => { unit => $raw->{unit}, rc => $raw->{systemctl_rc} },
                );
                $contract_state = 'unknown';
            }
            else {
                my $p = $raw->{properties};
                my $lifecycle = (($p->{Restart} // '') eq 'always'
                              && ($p->{ExitType} // '') eq 'cgroup') ? 1 : 0;
                my $exit75 = _status_has_75($p->{SuccessExitStatus})
                          && _status_has_75($p->{RestartPreventExitStatus});
                if ($lifecycle && $exit75) {
                    push @out, _fact(
                        domain => 'systemd', id => 'systemd.actual_contract', level => 'ok',
                        summary => 'actual systemd unit satisfies the MB645 lifecycle contract',
                        detail => "Restart=$p->{Restart}, ExitType=$p->{ExitType}, exit75 protected",
                        source => "systemctl show $raw->{unit}",
                        data => { unit => $raw->{unit}, lifecycle_safe => 1, exit75_safe => 1,
                                  restart => $p->{Restart}, exit_type => $p->{ExitType} },
                    );
                    $contract_state = 'safe';
                }
                elsif (!$lifecycle) {
                    my $legacy_supported = (!$raw->{marker_safe}
                        && $ctx->{builtin_updater_intentionally_inapplicable}) ? 1 : 0;
                    push @out, _fact(
                        domain => 'systemd', id => 'systemd.actual_contract',
                        level => ($legacy_supported ? 'info' : 'fail'),
                        summary => ($legacy_supported
                            ? 'MB645 lifecycle contract is not installed; built-in updater is not applicable to this deployment'
                            : 'actual systemd unit is NOT update-safe'),
                        detail => 'expected Restart=always and ExitType=cgroup for the built-in updater; got Restart='
                                . ($p->{Restart} // 'unknown') . ', ExitType=' . ($p->{ExitType} // 'unknown'),
                        source => "systemctl show $raw->{unit}",
                        data => { unit => $raw->{unit}, lifecycle_safe => 0, exit75_safe => ($exit75 ? 1 : 0),
                                  restart => $p->{Restart}, exit_type => $p->{ExitType},
                                  builtin_updater_applicable => ($legacy_supported ? 0 : 1) },
                    );
                    $contract_state = ($legacy_supported ? 'legacy_supported' : 'unsafe');
                }
                else {
                    push @out, _fact(
                        domain => 'systemd', id => 'systemd.actual_contract', level => 'warn',
                        summary => 'update lifecycle is safe but exit-75 shutdown policy is incomplete',
                        detail => 'Restart=always and ExitType=cgroup are present, but SuccessExitStatus/RestartPreventExitStatus do not both include 75',
                        source => "systemctl show $raw->{unit}",
                        data => { unit => $raw->{unit}, lifecycle_safe => 1, exit75_safe => 0 },
                    );
                    $contract_state = 'partial';
                }
            }
        }
        else {
            push @out, _fact(
                domain => 'systemd', id => 'systemd.actual_contract', level => 'info',
                summary => 'systemd lifecycle contract is not applicable to this running process',
                source => 'cgroup observation', data => { applicable => 0 },
            );
        }

        if ($raw->{marker_safe} && $contract_state ne 'safe') {
            push @out, _fact(
                domain => 'systemd', id => 'systemd.contract_consistency', level => 'fail',
                summary => 'safe-update marker disagrees with the verifiable unit contract',
                detail => "marker=1, contract=$contract_state",
                source => 'process environment + systemctl',
                data => { marker_safe => 1, contract => $contract_state },
            );
        }
        elsif (defined $raw->{unit} && $contract_state eq 'safe' && !$raw->{marker_safe}) {
            push @out, _fact(
                domain => 'systemd', id => 'systemd.contract_consistency', level => 'warn',
                summary => 'unit contract is safe but the running process lacks the MB645 marker',
                detail => 'restart the instance after installing the current unit environment',
                source => 'process environment + systemctl',
                data => { marker_safe => 0, contract => 'safe' },
            );
        }
        elsif (defined $raw->{unit} && $contract_state eq 'safe' && $raw->{marker_safe}) {
            push @out, _fact(
                domain => 'systemd', id => 'systemd.contract_consistency', level => 'ok',
                summary => 'runtime manager, safe-update marker and actual unit contract agree',
                source => 'process environment + systemctl',
                data => { marker_safe => 1, contract => 'safe' },
            );
        }

        return @out;
    };

    register_probe(domain => 'systemd', round => 2,
                   collect => $collect, evaluate => $evaluate);
}

# =============================================================================
# SONDE : updater / deploiement (round 2)
# =============================================================================
{
    my $collect = sub {
        my ($ctx) = @_;
        my %r;

        my $loaded = eval {
            local @INC = ($ctx->{root}, @INC);
            require Mediabot::Update;
            1;
        };
        unless ($loaded) {
            my $err = $@; $err =~ s/\s+/ /g;
            return { module_error => $err };
        }

        # Reuse protected_paths() itself, including its built-in path+host rule
        # and configured additions, instead of duplicating the parser here.
        {
            package Mediabot::Doctor::ConfView;
            sub new { bless { values => $_[1] }, $_[0] }
            sub get { return $_[0]{values}{$_[1]} }
            package Mediabot::Doctor::UpdateView;
            sub new { bless { conf => $_[1] }, $_[0] }
            package main;
        }
        my $view = Mediabot::Doctor::UpdateView->new(
            Mediabot::Doctor::ConfView->new($ctx->{conf_values}));
        my @protected = Mediabot::Update::protected_paths($view);
        my @hostnames = Mediabot::Update::current_hostnames();

        my $deploy = File::Spec->catfile($ctx->{root}, 'install', 'deploy_update.sh');
        my @dst = stat($deploy);
        my $deploy_exec = @dst ? ((($dst[2] & 0111) != 0) ? 1 : 0) : 0;

        my $parent = dirname($ctx->{root});
        my @pst = stat($parent);
        my $parent_writable;
        if (@pst) {
            my $entry = { mode => sprintf('%04o', $pst[2] & 07777), uid => $pst[4], gid => $pst[5] };
            $parent_writable = _identity_access($entry, $ctx, 'write');
            $parent_writable = (-w $parent ? 1 : 0) unless defined $parent_writable;
        }
        else { $parent_writable = 0 }

        my ($eligible, $why) = Mediabot::Update::update_eligibility(
            project_dir => _normalize_path($ctx->{root}, $ctx->{root}),
            protected   => \@protected,
            hostnames   => \@hostnames,
            exists      => {
                'mediabot.pl'              => (-f File::Spec->catfile($ctx->{root}, 'mediabot.pl') ? 1 : 0),
                'install/deploy_update.sh' => (-f $deploy ? 1 : 0),
                deploy_executable          => $deploy_exec,
                parent_writable            => ($parent_writable ? 1 : 0),
            },
        );
        $r{eligible} = $eligible ? 1 : 0;
        $r{eligibility_reason} = $why;
        $r{hostnames} = \@hostnames;

        $r{family} = _scan_deployment_family($ctx->{root});

        # Git inspection is local-only. No fetch, no ls-remote, no network.
        my $git = _find_executable('git');
        $r{git_executable} = $git;
        if (defined $git) {
            my $inside = _capture_command($git, '-C', $ctx->{root}, 'rev-parse', '--is-inside-work-tree');
            if ($inside->{ok} && $inside->{stdout} =~ /true/) {
                $r{git}{is_repo} = 1;
                for my $spec (
                    [ branch => 'rev-parse', '--abbrev-ref', 'HEAD' ],
                    [ head   => 'rev-parse', 'HEAD' ],
                    [ upstream => 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}' ],
                ) {
                    my ($key, @args) = @$spec;
                    my $got = _capture_command($git, '-C', $ctx->{root}, @args);
                    if ($got->{ok}) {
                        $got->{stdout} =~ s/\s+\z//;
                        $r{git}{$key} = $got->{stdout};
                    }
                }
                my $dirty = _capture_command($git, '-C', $ctx->{root}, 'status', '--porcelain', '--untracked-files=normal');
                if ($dirty->{ok}) {
                    my @lines = grep { length } split /\n/, $dirty->{stdout};
                    $r{git}{dirty_count} = scalar @lines;
                }
                if (defined $r{git}{upstream}) {
                    my $div = _capture_command($git, '-C', $ctx->{root}, 'rev-list', '--left-right', '--count',
                                               $r{git}{upstream} . '...HEAD');
                    if ($div->{ok} && $div->{stdout} =~ /\A\s*(\d+)\s+(\d+)\s*\z/) {
                        $r{git}{behind_cached} = int($1);
                        $r{git}{ahead_cached}  = int($2);
                    }
                }
            }
            else {
                $r{git}{is_repo} = 0;
            }
        }

        return \%r;
    };

    my $evaluate = sub {
        my ($raw, $ctx) = @_;
        my @out;

        if ($raw->{module_error}) {
            return _fact(
                domain => 'updater', id => 'updater.module', level => 'unknown',
                summary => 'cannot load Mediabot::Update', detail => $raw->{module_error},
                source => 'Mediabot/Update.pm', data => {},
            );
        }

        if ($raw->{eligible}) {
            push @out, _fact(
                domain => 'updater', id => 'updater.eligibility', level => 'ok',
                summary => 'built-in updater is eligible for this installation',
                source => 'Mediabot::Update::update_eligibility',
                data => { eligible => 1 },
            );
        }
        else {
            my $why = $raw->{eligibility_reason} // 'unspecified reason';
            my $intentional = ($why =~ /\bprotected\b/i
                            || $why =~ /unexpected project directory name/i) ? 1 : 0;
            push @out, _fact(
                domain => 'updater', id => 'updater.eligibility',
                level => ($intentional ? 'info' : 'warn'),
                summary => ($intentional
                    ? 'built-in updater is intentionally not applicable here'
                    : 'built-in updater is currently not operational'),
                detail => $why,
                source => 'Mediabot::Update::update_eligibility',
                data => { eligible => 0, intentional => $intentional },
            );
        }

        my $fam = $raw->{family};
        if (!$fam || !$fam->{ok}) {
            push @out, _fact(
                domain => 'updater', id => 'updater.deployment_family', level => 'unknown',
                summary => 'cannot inspect deployment-family archives',
                detail => ($fam ? $fam->{error} : undef), source => 'filesystem:parent(root)', data => {},
            );
        }
        else {
            my $n = scalar @{ $fam->{archives} // [] };
            my $ignored = scalar @{ $fam->{ignored_sibling_families} // [] };
            push @out, _fact(
                domain => 'updater', id => 'updater.deployment_family', level => 'ok',
                summary => "deployment family '$fam->{family}' isolated ($n archive(s))",
                detail => $ignored ? "$ignored sibling-family archive(s) explicitly ignored" : undef,
                source => "directory:$fam->{parent}",
                data => { family => $fam->{family}, archive_count => $n,
                          archives => $fam->{archives}, ignored_sibling_count => $ignored,
                          exact_family_filter => 1 },
            );
        }

        if (!defined $raw->{git_executable}) {
            push @out, _fact(
                domain => 'updater', id => 'updater.git', level => 'info',
                summary => 'git executable not available; Git state not inspected',
                source => 'PATH:git', data => { network_used => 0 },
            );
        }
        elsif (!$raw->{git}{is_repo}) {
            push @out, _fact(
                domain => 'updater', id => 'updater.git', level => 'info',
                summary => 'application root is not a Git checkout (supported deployment style)',
                source => 'git rev-parse', data => { is_repo => 0, network_used => 0 },
            );
        }
        else {
            my $dirty = $raw->{git}{dirty_count} // 0;
            push @out, _fact(
                domain => 'updater', id => 'updater.git', level => ($dirty ? 'warn' : 'ok'),
                summary => $dirty ? "Git working tree has $dirty local/untracked change(s)"
                                  : 'Git working tree is clean',
                detail => 'remote divergence below uses cached refs only; Doctor never fetches',
                source => 'local git metadata',
                data => { is_repo => 1, branch => $raw->{git}{branch}, head => $raw->{git}{head},
                          upstream => $raw->{git}{upstream}, dirty_count => $dirty,
                          ahead_cached => $raw->{git}{ahead_cached}, behind_cached => $raw->{git}{behind_cached},
                          network_used => 0 },
            );
            if (defined $raw->{git}{upstream} && defined $raw->{git}{ahead_cached}) {
                push @out, _fact(
                    domain => 'updater', id => 'updater.git_cached_divergence', level => 'info',
                    summary => "cached upstream divergence: ahead $raw->{git}{ahead_cached}, behind $raw->{git}{behind_cached}",
                    detail => "upstream $raw->{git}{upstream}; no network fetch performed",
                    source => 'git rev-list cached upstream',
                    data => { upstream => $raw->{git}{upstream}, ahead => $raw->{git}{ahead_cached},
                              behind => $raw->{git}{behind_cached}, network_used => 0 },
                );
            }
        }

        return @out;
    };

    register_probe(domain => 'updater', round => 2,
                   collect => $collect, evaluate => $evaluate);
}

# =============================================================================
# SONDE : database (round 3)
# =============================================================================
{
    my $collect = sub {
        my ($ctx) = @_;
        my ($dbh, $meta) = _doctor_db_connect($ctx);
        return { connected => 0, meta => $meta } unless $dbh;

        my %r = (connected => 1, meta => $meta);
        my ($session, $session_err) = _db_select_one($dbh, q{
            SELECT DATABASE() AS dbname,
                   VERSION() AS server_version,
                   @@character_set_client AS character_set_client,
                   @@character_set_connection AS character_set_connection,
                   @@character_set_results AS character_set_results,
                   @@collation_connection AS collation_connection
        });
        $r{session} = $session if $session;
        $r{session_error} = $session_err if $session_err;

        my @required = qw(
            ACHIEVEMENT_PROFILE ACHIEVEMENT_IDENTITY
            ACHIEVEMENT_UNLOCK ACHIEVEMENT_PROGRESS
        );
        my ($tables, $table_err) = _db_select_all($dbh, q{
            SELECT TABLE_NAME, ENGINE, TABLE_COLLATION
              FROM information_schema.TABLES
             WHERE TABLE_SCHEMA = DATABASE()
               AND TABLE_NAME IN (
                   'ACHIEVEMENT_PROFILE', 'ACHIEVEMENT_IDENTITY',
                   'ACHIEVEMENT_UNLOCK', 'ACHIEVEMENT_PROGRESS'
               )
             ORDER BY TABLE_NAME
        });
        $r{achievement_tables} = $tables if $tables;
        $r{achievement_table_error} = $table_err if $table_err;
        $r{achievement_required} = \@required;

        eval { $dbh->disconnect };

        # Schema truth stays in the existing checker. --ignore-extra asks the
        # operational question Doctor needs: are all REQUIRED current
        # structures/indexes/reference rows present? Extra legacy objects are
        # not a reason to declare the instance unsafe.
        my $checker = File::Spec->catfile($ctx->{root}, 'tools', 'check_schema_drift.pl');
        if (-f $checker && !-l $checker) {
            $r{schema_drift} = _capture_command_bounded(
                30, $^X, $checker, '--conf=' . $ctx->{conf_file},
                '--strict', '--types', '--indexes', '--ignore-extra', '--quiet');
        }
        else {
            $r{schema_drift} = { ok => 0, rc => 127, missing_tool => 1,
                                 stderr => 'tools/check_schema_drift.pl missing' };
        }
        return \%r;
    };

    my $evaluate = sub {
        my ($raw, $ctx) = @_;
        my @out;
        my $meta = $raw->{meta} || {};

        unless ($raw->{connected}) {
            return _fact(
                domain => 'database', id => 'database.connection', level => 'unknown',
                summary => 'database could not be inspected safely',
                detail => _sanitize_diag_text($meta->{error} || 'connection unavailable'),
                source => 'Mediabot::DB::connect_isolated_handle',
                data => { connected => 0, read_only_enforced => 0,
                          dbname => $meta->{dbname}, host => $meta->{dbhost}, port => $meta->{dbport} },
            );
        }

        my $session = $raw->{session} || {};
        my $db_name = $session->{dbname} || $meta->{dbname} || '(unknown)';
        my $driver = $meta->{driver} || 'DBI';
        my $driver_v = $meta->{driver_version} ? " $meta->{driver_version}" : '';
        push @out, _fact(
            domain => 'database', id => 'database.connection', level => 'ok',
            summary => "connected read-only to database '$db_name' via DBD::$driver$driver_v",
            source => 'Mediabot::DB::connect_isolated_handle + SET SESSION TRANSACTION READ ONLY',
            data => { connected => 1, read_only_enforced => 1, dbname => $db_name,
                      host => $meta->{dbhost}, port => $meta->{dbport}, driver => $driver,
                      driver_version => $meta->{driver_version}, server_version => $session->{server_version} },
        );

        if ($raw->{session_error}) {
            push @out, _fact(
                domain => 'database', id => 'database.session_charset', level => 'unknown',
                summary => 'database session charset could not be verified',
                detail => _sanitize_diag_text($raw->{session_error}),
                source => 'SELECT @@character_set_* / @@collation_connection', data => {},
            );
        }
        else {
            my $mode = lc($meta->{charset_mode} // 'utf8mb4');
            my $cs = $session->{character_set_connection} // '';
            my $coll = $session->{collation_connection} // '';
            my $expected = $mode eq 'latin1' ? 'latin1' : ($mode eq 'off' ? undef : 'utf8mb4');
            my $level = !defined($expected) ? 'info' : ($cs eq $expected ? 'ok' : 'warn');
            my $summary = !defined($expected)
                ? "charset mode is off; live connection uses $cs / $coll"
                : ($cs eq $expected
                    ? "session charset $cs / $coll"
                    : "session charset $cs does not match configured mode $expected");
            push @out, _fact(
                domain => 'database', id => 'database.session_charset', level => $level,
                summary => $summary,
                source => 'live DB session variables + mysql.CHARSET_MODE',
                data => { configured_mode => $mode,
                          character_set_client => $session->{character_set_client},
                          character_set_connection => $session->{character_set_connection},
                          character_set_results => $session->{character_set_results},
                          collation_connection => $session->{collation_connection} },
            );
        }

        if ($raw->{achievement_table_error}) {
            push @out, _fact(
                domain => 'database', id => 'database.achievement_storage', level => 'unknown',
                summary => 'MB646 achievement persistence tables could not be inspected',
                detail => _sanitize_diag_text($raw->{achievement_table_error}),
                source => 'information_schema.TABLES', data => {},
            );
        }
        else {
            my @required = @{ $raw->{achievement_required} || [] };
            my @rows = @{ $raw->{achievement_tables} || [] };
            my %present = map { ($_->{TABLE_NAME} // $_->{table_name} // '') => $_ } @rows;
            my @missing = grep { !$present{$_} } @required;
            if (!@missing && @required) {
                my @nonstandard;
                for my $name (@required) {
                    my $row = $present{$name} || {};
                    my $engine = $row->{ENGINE} // $row->{engine} // '';
                    my $coll = $row->{TABLE_COLLATION} // $row->{table_collation} // '';
                    push @nonstandard, "$name(engine=$engine,collation=$coll)"
                        unless lc($engine) eq 'innodb' && lc($coll) eq 'utf8mb4_unicode_ci';
                }
                push @out, _fact(
                    domain => 'database', id => 'database.achievement_storage',
                    level => (@nonstandard ? 'warn' : 'ok'),
                    summary => (@nonstandard
                        ? 'all MB646 achievement tables exist but storage metadata differs from the reference'
                        : 'MB646 achievement persistence tables present (MariaDB storage available)'),
                    detail => (@nonstandard ? join(', ', @nonstandard) : undef),
                    source => 'information_schema.TABLES + Mediabot::Achievements::_db_schema_available',
                    data => { storage => 'db', present => scalar(@rows), required => scalar(@required),
                              missing => \@missing },
                );
            }
            elsif (!@rows) {
                push @out, _fact(
                    domain => 'database', id => 'database.achievement_storage', level => 'warn',
                    summary => 'MB646 achievement tables are absent; Mediabot will use legacy JSON fallback',
                    detail => 'apply install/migrations/20260816_achievements_db.sql before relying on DB persistence',
                    source => 'information_schema.TABLES + Mediabot::Achievements::_db_schema_available',
                    data => { storage => 'json_fallback', present => 0,
                              required => scalar(@required), missing => \@missing },
                );
            }
            else {
                push @out, _fact(
                    domain => 'database', id => 'database.achievement_storage', level => 'fail',
                    summary => 'partial MB646 achievement schema detected',
                    detail => 'missing: ' . join(', ', @missing),
                    source => 'information_schema.TABLES + Mediabot::Achievements::_db_schema_available',
                    data => { storage => 'partial', present => scalar(@rows),
                              required => scalar(@required), missing => \@missing },
                );
            }
        }

        my $drift = $raw->{schema_drift} || {};
        if ($drift->{ok}) {
            push @out, _fact(
                domain => 'database', id => 'database.schema_drift', level => 'ok',
                summary => 'required live schema/reference data match install/mediabot.sql',
                detail => 'delegated to check_schema_drift.pl (--types --indexes --ignore-extra)',
                source => 'tools/check_schema_drift.pl',
                data => { delegated => 1, rc => 0, network_used => 0, extra_live_objects_ignored => 1 },
            );
        }
        elsif ($drift->{timeout}) {
            push @out, _fact(
                domain => 'database', id => 'database.schema_drift', level => 'unknown',
                summary => 'schema drift checker timed out',
                detail => 'bounded at 30 seconds; no schema change was attempted',
                source => 'tools/check_schema_drift.pl', data => { delegated => 1, rc => 124 },
            );
        }
        elsif (($drift->{rc} // 127) == 1) {
            my $evidence = ($drift->{stdout} // '') . "\n" . ($drift->{stderr} // '');
            my $critical_missing = ($evidence =~ /\bMISSING\s+(?:TABLE|COLUMN|DATA)\b/i) ? 1 : 0;
            my $detail = _sanitize_diag_text($evidence, 900);
            push @out, _fact(
                domain => 'database', id => 'database.schema_drift',
                level => ($critical_missing ? 'fail' : 'warn'),
                summary => ($critical_missing
                    ? 'required schema/reference objects are missing'
                    : 'schema/reference drift detected (types/indexes or other non-missing differences)'),
                detail => $detail || 'run tools/check_schema_drift.pl manually for details',
                source => 'tools/check_schema_drift.pl',
                data => { delegated => 1, rc => 1, extra_live_objects_ignored => 1,
                          critical_missing => $critical_missing },
            );
        }
        else {
            my $detail = _sanitize_diag_text(($drift->{stderr} // '') . ' ' . ($drift->{stdout} // ''), 500);
            push @out, _fact(
                domain => 'database', id => 'database.schema_drift', level => 'unknown',
                summary => 'schema drift checker could not complete',
                detail => $detail || 'checker unavailable',
                source => 'tools/check_schema_drift.pl',
                data => { delegated => 1, rc => ($drift->{rc} // 127) },
            );
        }

        return @out;
    };

    register_probe(domain => 'database', round => 3,
                   collect => $collect, evaluate => $evaluate);
}

# =============================================================================
# SONDE : migrations (round 3)
# =============================================================================
{
    my $collect = sub {
        my ($ctx) = @_;
        my $dir = File::Spec->catdir($ctx->{root}, 'install', 'migrations');
        return { directory_error => 'install/migrations directory missing' }
            unless -d $dir && !-l $dir;

        opendir(my $dh, $dir) or return { directory_error => "cannot open migrations directory: $!" };
        my @names = sort grep { /\.sql\z/ && -f File::Spec->catfile($dir, $_)
                                        && !-l File::Spec->catfile($dir, $_) } readdir($dh);
        closedir $dh;

        my @migrations;
        for my $name (@names) {
            my $path = File::Spec->catfile($dir, $name);
            my $spec = _migration_observables($path);
            push @migrations, { name => $name, path => $path, %$spec };
        }

        my ($dbh, $meta) = _doctor_db_connect($ctx);
        return { migrations => \@migrations, db_error => $meta->{error}, db_meta => $meta }
            unless $dbh;

        for my $mig (@migrations) {
            my @observed;
            for my $effect (@{ $mig->{effects} || [] }) {
                my ($row, $err);
                if ($effect->{type} eq 'table') {
                    ($row, $err) = _db_select_one($dbh, q{
                        SELECT 1 AS present FROM information_schema.TABLES
                         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? LIMIT 1
                    }, $effect->{table});
                }
                elsif ($effect->{type} eq 'column') {
                    ($row, $err) = _db_select_one($dbh, q{
                        SELECT 1 AS present FROM information_schema.COLUMNS
                         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ? LIMIT 1
                    }, $effect->{table}, $effect->{column});
                }
                elsif ($effect->{type} eq 'index') {
                    ($row, $err) = _db_select_one($dbh, q{
                        SELECT 1 AS present FROM information_schema.STATISTICS
                         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND INDEX_NAME = ? LIMIT 1
                    }, $effect->{table}, $effect->{index});
                }
                elsif ($effect->{type} eq 'constraint') {
                    ($row, $err) = _db_select_one($dbh, q{
                        SELECT 1 AS present FROM information_schema.TABLE_CONSTRAINTS
                         WHERE CONSTRAINT_SCHEMA = DATABASE() AND TABLE_NAME = ? AND CONSTRAINT_NAME = ? LIMIT 1
                    }, $effect->{table}, $effect->{constraint});
                }
                elsif ($effect->{type} eq 'chanset') {
                    ($row, $err) = _db_select_one($dbh,
                        'SELECT 1 AS present FROM CHANSET_LIST WHERE chanset = ? LIMIT 1',
                        $effect->{chanset});
                }
                push @observed, { %$effect,
                    state => ($err ? 'indeterminate' : ($row ? 'present' : 'missing')),
                    (defined $err ? (error => $err) : ()),
                };
            }
            $mig->{observed} = \@observed;
        }
        eval { $dbh->disconnect };
        return { migrations => \@migrations, db_meta => $meta };
    };

    my $evaluate = sub {
        my ($raw, $ctx) = @_;
        if ($raw->{directory_error}) {
            return _fact(
                domain => 'migrations', id => 'migrations.inventory', level => 'unknown',
                summary => 'migration inventory could not be inspected',
                detail => $raw->{directory_error}, source => 'install/migrations', data => {},
            );
        }

        my @migrations = @{ $raw->{migrations} || [] };
        my @out;
        push @out, _fact(
            domain => 'migrations', id => 'migrations.inventory',
            level => (@migrations ? 'ok' : 'warn'),
            summary => scalar(@migrations) . ' migration file(s) discovered',
            source => 'directory:install/migrations',
            data => { count => scalar(@migrations), names => [ map { $_->{name} } @migrations ] },
        );

        if ($raw->{db_error}) {
            push @out, _fact(
                domain => 'migrations', id => 'migrations.observable_state', level => 'unknown',
                summary => 'migration observable effects could not be compared with the live database',
                detail => _sanitize_diag_text($raw->{db_error}),
                source => 'read-only database session + install/migrations/*.sql',
                data => { states => [] },
            );
            return @out;
        }

        my (@present, @missing, @indeterminate, @states, @missing_details);
        my $effect_label = sub {
            my ($e) = @_;
            return 'table ' . ($e->{table} // '?') if ($e->{type} // '') eq 'table';
            return 'column ' . ($e->{table} // '?') . '.' . ($e->{column} // '?')
                if ($e->{type} // '') eq 'column';
            return 'index ' . ($e->{table} // '?') . '.' . ($e->{index} // '?')
                if ($e->{type} // '') eq 'index';
            return 'constraint ' . ($e->{table} // '?') . '.' . ($e->{constraint} // '?')
                if ($e->{type} // '') eq 'constraint';
            return 'chanset ' . ($e->{chanset} // '?') if ($e->{type} // '') eq 'chanset';
            return ($e->{type} // 'effect');
        };
        for my $mig (@migrations) {
            my $state;
            my @obs = @{ $mig->{observed} || [] };
            my @missing_obs = grep { ($_->{state} // '') eq 'missing' } @obs;
            if ($mig->{unsupported_mutation} || !@{ $mig->{effects} || [] }) {
                $state = 'indeterminate';
            }
            elsif (grep { ($_->{state} // '') eq 'indeterminate' } @obs) {
                $state = 'indeterminate';
            }
            elsif (@missing_obs) {
                $state = 'observable_effect_missing';
            }
            else {
                $state = 'observable_effect_present';
            }
            push @{ $state eq 'observable_effect_present' ? \@present
                    : $state eq 'observable_effect_missing' ? \@missing : \@indeterminate },
                 $mig->{name};
            my @labels = map { $effect_label->($_) } @missing_obs;
            push @missing_details, $mig->{name} . ': ' . join(', ', @labels) if @labels;
            push @states, { name => $mig->{name}, state => $state,
                            effect_count => scalar(@{ $mig->{effects} || [] }),
                            missing_effects => \@labels };
        }

        my ($level, $summary, $detail);
        if (@missing) {
            $level = 'warn';
            $summary = scalar(@missing) . ' migration file(s) have observable effects missing';
            $detail = 'missing observable effects: ' . join('; ', @missing_details);
            $detail .= '; indeterminate: ' . join(', ', @indeterminate) if @indeterminate;
            $detail .= '; this does NOT prove the migration file was never executed';
        }
        elsif (@indeterminate) {
            $level = 'unknown';
            $summary = scalar(@indeterminate) . ' migration file(s) are indeterminate from observable state';
            $detail = 'indeterminate: ' . join(', ', @indeterminate);
        }
        else {
            $level = 'ok';
            $summary = 'all migration files have their observable effects present';
            $detail = scalar(@present) . ' file(s); this proves current observable state, NOT historical execution';
        }

        push @out, _fact(
            domain => 'migrations', id => 'migrations.observable_state', level => $level,
            summary => $summary, detail => $detail,
            source => 'install/migrations/*.sql + live read-only information_schema/reference queries',
            data => { states => \@states, present => \@present, missing => \@missing,
                      indeterminate => \@indeterminate,
                      historical_execution_proven => 0 },
        );
        return @out;
    };

    register_probe(domain => 'migrations', round => 3,
                   collect => $collect, evaluate => $evaluate);
}

# =============================================================================
# 4. Contexte, orchestration, rendus
# =============================================================================
sub _worse {
    my ($a, $b) = @_;
    return (($LEVEL_RANK{$b} // 0) > ($LEVEL_RANK{$a} // 0)) ? $b : $a;
}

sub build_context {
    my (%opt) = @_;

    my $root = $opt{root};
    unless (defined $root && length $root) {
        $root = dirname(dirname(__FILE__));
    }
    $root = File::Spec->rel2abs($root);

    my $conf_file = $opt{conf};
    $conf_file = File::Spec->catfile($root, 'mediabot.conf')
        unless defined $conf_file && length $conf_file;
    $conf_file = File::Spec->rel2abs($conf_file, $root)
        unless File::Spec->file_name_is_absolute($conf_file);

    my @sources;
    for my $dir ($root, File::Spec->catdir($root, 'Mediabot'),
                 File::Spec->catdir($root, 'Mediabot', 'External')) {
        opendir(my $dh, $dir) or next;
        push @sources, map  { File::Spec->catfile($dir, $_) }
                       grep { /\.(?:pm|pl)\z/ } readdir($dh);
        closedir $dh;
    }

    my %conf_values;
    if (open my $fh, '<:raw', $conf_file) {
        my $section = '';
        while (my $line = <$fh>) {
            next if $line =~ /^\s*[#;]/;
            $section = $1 if $line =~ /^\s*\[([a-z_]+)\]/;
            if ($line =~ /^\s*([A-Z_0-9]+)\s*=\s*(.*?)\s*$/ && $section ne '') {
                my ($k, $v) = ("$section.$1", $2);
                $v =~ s/\A["']//; $v =~ s/["']\z//;
                # Meme ici, aucune valeur de secret n'est conservee.
                $conf_values{$k} = is_secret_key($1) ? undef : $v;
            }
        }
        close $fh;
    }

    return {
        root         => $root,
        conf_file    => $conf_file,
        sample_conf  => File::Spec->catfile($root, 'mediabot.sample.conf'),
        source_files => \@sources,
        conf_values  => \%conf_values,
        _defaulted   => {},
        expected_uid => undef,
        expected_gids => [],
        expected_uid_source => undef,
        observed_pid => undef,
        observed_runtime_manager => undef,
        main_program_invocation_mode => undef,
        main_program_launcher => undef,
    };
}

sub run_probes {
    my ($ctx, %opt) = @_;
    my @facts;

    # Some domains depend on facts established by another probe.  Domain
    # filtering must never change the truth being diagnosed: asking only for
    # systemd/filesystem still needs the runtime probe to establish the live
    # PID and runtime identity.  Dependency probes run silently unless the
    # caller explicitly requested their domain.
    my %requested = $opt{only} ? %{ $opt{only} } : map { $_ => 1 } @DOMAINS;
    my %needed    = %requested;
    if ($opt{only}) {
        # updater needs the observed runtime identity for parent-directory
        # writability; filesystem needs it for permission checks; systemd needs
        # runtime plus updater applicability to grade MB645 contract drift in
        # the context of the deployment actually in use.
        $needed{runtime} = 1 if $requested{systemd} || $requested{filesystem} || $requested{updater};
        $needed{updater} = 1 if $requested{systemd};
    }

    # Dependency order is deliberate: runtime establishes PID/identity, updater
    # establishes whether the built-in updater is applicable, then systemd can
    # evaluate the MB645 lifecycle contract without confusing "legacy" with
    # "unsafe for this deployment".
    my @order = ('runtime', 'updater', grep { $_ ne 'runtime' && $_ ne 'updater' } @DOMAINS);

    for my $domain (@order) {
        next unless $needed{$domain};
        my $probe = $PROBES{$domain} or next;

        my @domain_facts = eval {
            # Une sonde peut rendre une LISTE de faits bruts ou une structure
            # unique ; l'evaluateur recoit toujours la meme forme. Sans cette
            # normalisation, « filesystem » (liste) et « config » (hashref)
            # auraient des contrats differents — exactement ce que l'interface
            # commune doit empecher.
            my @raw = $probe->{collect}->($ctx);
            my $payload = (@raw == 1 && ref $raw[0] eq 'HASH') ? $raw[0] : \@raw;
            $probe->{evaluate}->($payload, $ctx);
        };
        if ($@) {
            my $err = $@;
            $err =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*\z//;
            $err =~ s/\s+/ /g;
            # Une sonde qui echoue devient un fait UNKNOWN : elle n'emporte
            # jamais l'orchestrateur, et son echec est visible.
            @domain_facts = _fact(
                domain => $domain, id => "$domain.probe_error", level => 'unknown',
                summary => 'probe failed', detail => substr($err, 0, 200),
                source => 'doctor', data => {},
            );
        }

        # Le uid observe du processus devient la reference attendue.
        for my $f (@domain_facts) {
            if ($f->{id} eq 'runtime.process_owner') {
                $ctx->{expected_uid}        = $f->{data}{uid};
                $ctx->{expected_gids}       = $f->{data}{gids} // [];
                $ctx->{expected_uid_source} = 'running process';
            }
            if ($f->{id} eq 'runtime.state' && $f->{data}{running} && defined $f->{data}{pid}) {
                $ctx->{observed_pid} = $f->{data}{pid};
                $ctx->{main_program_invocation_mode} = $f->{data}{invocation_mode}
                    if defined $f->{data}{invocation_mode};
                $ctx->{main_program_launcher} = $f->{data}{launcher}
                    if defined $f->{data}{launcher};
            }
            if ($f->{id} eq 'updater.eligibility') {
                $ctx->{builtin_updater_eligible} = $f->{data}{eligible} ? 1 : 0;
                $ctx->{builtin_updater_intentionally_inapplicable} =
                    (!$f->{data}{eligible} && $f->{data}{intentional}) ? 1 : 0;
                $ctx->{builtin_updater_reason} = $f->{detail} if defined $f->{detail};
            }
        }

        # A dependency probe may run only to enrich context.  Keep --domain
        # output scoped to what the operator asked for while still diagnosing
        # it with the same facts as an unfiltered run.
        push @facts, @domain_facts if $requested{$domain};
    }

    return \@facts;
}

sub render_text {
    my ($report) = @_;
    my %icon = (ok => '  ok  ', info => ' info ', unknown => '  ??  ',
                warn => ' WARN ', fail => ' FAIL ');
    my @lines;
    push @lines, "Mediabot Doctor $VERSION — $report->{root}";
    push @lines, sprintf('%s  |  schema %d', $report->{generated_at}, $report->{schema_version});
    push @lines, '';

    for my $domain (@DOMAINS) {
        my @f = grep { $_->{domain} eq $domain } @{ $report->{findings} };
        next unless @f;
        push @lines, uc($domain);
        for my $f (@f) {
            push @lines, sprintf('  [%s] %s', $icon{ $f->{level} }, $f->{summary});
            push @lines, '          ' . $f->{detail} if defined $f->{detail};
        }
        push @lines, '';
    }

    my $s = $report->{summary};
    push @lines, "Result: $report->{result}";
    push @lines, sprintf('%d finding(s): %d ok, %d info, %d unknown, %d warn, %d fail',
        $s->{total}, $s->{ok}, $s->{info}, $s->{unknown}, $s->{warn}, $s->{fail});
    return join("\n", @lines) . "\n";
}

sub render_json {
    my ($report) = @_;
    require JSON::PP;
    return JSON::PP->new->canonical->pretty->encode($report) ;
}

sub build_report {
    my ($ctx, $facts) = @_;
    my %count = map { $_ => 0 } @LEVELS;
    for my $fact (@$facts) {
        die "report: invalid fact level '$fact->{level}'\n"
            unless exists $count{$fact->{level}};
        $count{ $fact->{level} }++;
    }

    my $result = $count{fail} ? 'UNSAFE'
               : ($count{warn} || $count{unknown}) ? 'DEGRADED'
               : 'READY';

    return {
        schema_version => SCHEMA_VERSION,
        tool           => 'mediabot_doctor',
        tool_version   => $VERSION,
        generated_at   => strftime('%Y-%m-%dT%H:%M:%S%z', localtime()),
        root           => $ctx->{root},
        conf_file      => $ctx->{conf_file},
        domains        => [ @DOMAINS ],
        result         => $result,
        findings       => $facts,
        summary        => { total => scalar(@$facts), %count },
    };
}

sub exit_code_for {
    my ($report, $strict) = @_;
    return 1 if $report->{summary}{fail};
    return 1 if $strict && ($report->{summary}{warn} || $report->{summary}{unknown});
    return 0;
}

# --- point d'entree ----------------------------------------------------------
unless (caller) {
    my %opt = (format => 'text');
    GetOptions(
        'root=s'   => \$opt{root},
        'conf=s'   => \$opt{conf},
        'json'     => sub { $opt{format} = 'json' },
        'domain=s@' => \$opt{domain},
        'strict'   => \$opt{strict},
        'help'     => \$opt{help},
    ) or _usage(1);
    _usage(0) if $opt{help};

    my $ctx = build_context(root => $opt{root}, conf => $opt{conf});
    my %only;
    if ($opt{domain}) {
        for my $domain (map { split /,/ } @{ $opt{domain} }) {
            unless ($DOMAIN_SET{$domain}) {
                print STDERR "Unknown domain '$domain'. Valid domains: "
                           . join(', ', @DOMAINS) . "\n";
                exit 2;
            }
            $only{$domain} = 1;
        }
    }
    my $facts  = run_probes($ctx, ($opt{domain} ? (only => \%only) : ()));
    my $report = build_report($ctx, $facts);

    print $opt{format} eq 'json' ? render_json($report) : render_text($report);
    exit exit_code_for($report, $opt{strict});
}

sub _usage {
    my ($code) = @_;
    print <<"USAGE";
Mediabot Doctor $VERSION — read-only diagnosis of a Mediabot instance

  tools/mediabot_doctor.pl [--root DIR] [--conf FILE] [--json]
                           [--domain NAME] [--strict]

  --root DIR     project directory (default: the tree this script lives in)
  --conf FILE    configuration file (default: <root>/mediabot.conf)
  --json         machine-readable output (schema_version @{[SCHEMA_VERSION]})
  --domain NAME  restrict to one domain, repeatable
                 (@{[ join ', ', @DOMAINS ]})
  --strict       exit 1 on warnings or unknowns too (default: only failures)

This tool never writes persistent data or schema, never signals the bot, and never
collects a secret value into its fact model. Database diagnostics use read-only
sessions and SELECT/information_schema queries only.
USAGE
    exit $code;
}

1;
