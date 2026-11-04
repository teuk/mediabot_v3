# t/cases/744_mb548_db_lag_hardening.t
# =============================================================================
# mb547 — diagnostic et blindage du « premier m check qui lag 10 s » (instance
# Undernet) : le pattern premier-hit-lent/suivants-ok pointe une connexion DB
# idle tuée en silence (wait_timeout/conntrack), payée par le premier humain.
#
# Trois volets contractés :
#   [1] DSN borné : mariadb_connect_timeout/read/write présents sur TOUS
#       les sites de construction, clés mysql.*_TIMEOUT bornées (garbage/0 ->
#       défauts) ;
#   [2] ensure_connected chronométré : ping lent -> ligne niveau 3 avec
#       durée ; reconnexion -> durée logguée niveau 1 (ok/FAILED) ; chemin
#       rapide silencieux ;
#   [3] tick DB canonique : le health check A4 déjà présent reste l'unique
#       keepalive (pas de double ping ajouté) et synchronise le dbh legacy ;
#   [4] wrapper de chrono PRIVMSG : tout traitement > 1 s logge SLOW PRIVMSG
#       avec durée et origine (gardes statiques : wrapper + corps renommé +
#       une seule définition du corps) ;
#   [5] sample.conf documente les trois clés (contrat 615 déjà vert).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_744 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package L744;
    sub new { bless { lines => [] }, shift }
    sub log { my ($self, $level, $msg) = @_; push @{ $self->{lines} }, [ $level, $msg ]; 1 }
    sub texts { map { $_->[1] } @{ $_[0]->{lines} } }
    sub at_level { my ($self, $level) = @_; grep { $_->[0] == $level } @{ $_[0]->{lines} } }
}

{
    # Faux dbh pilotable : ping ok / lent / mort.
    package DBH744;
    sub new { my ($class, %h) = @_; bless { %h }, $class }
    sub ping {
        my ($self) = @_;
        select(undef, undef, undef, $self->{ping_delay}) if $self->{ping_delay};
        return $self->{alive} ? 1 : 0;
    }
}


# MB1092: local DBI wire model, including the driver's silent reconnect path.
# No database credentials, socket, worker process or server are used.
{
    package MB1092::Conf;
    sub get {$_[0]{$_[1]}}
    package MB1092::Metrics;
    sub set {$_[0]{up}=$_[2] if $_[1] eq 'mediabot_db_up';1}
    sub inc {$_[0]{$_[2]{result}}++ if $_[1] eq 'mediabot_db_reconnects_total';1}
    package MB1092::Handle;
    sub new {my ($c,%a)=@_;bless {init=>$a{init}//'',attrs=>$a{attrs},fault=>$a{fault}//'',at=>$a{at}//0,
        cleanup=>$a{cleanup}//0,sql=>[],statements=>[],step=>0,charset=>'server_default',zone=>'+02:00'},$c}
    sub prepare {
        my ($h,$sql)=@_;my $step=$sql=~/\ASET /?++$h->{step}:0;
        push @{$h->{sql}},$sql;
        if ($step && $step==$h->{at}) {
            return if $h->{fault} eq 'prepare_false';
            die "fixture prepare failure\n" if $h->{fault} eq 'prepare_throw';
        }
        my $st=bless {db=>$h,sql=>$sql,step=>$step,error=>0,finished=>0},'MB1092::Statement';
        push @{$h->{statements}},$st;return $st;
    }
    sub driver_init {
        my ($h)=@_;
        return unless length($h->{init});
        $h->{zone}='+00:00' if $h->{init}=~/time_zone = '\+00:00'/;
        # The native driver enforces UTF-8 after MYSQL_INIT_COMMAND.
        $h->{charset}='utf8mb4';
        $h->{init_calls}++;
    }
    sub ping {
        my ($h)=@_;
        if ($h->{broken} && $h->{attrs}{mariadb_auto_reconnect}) {
            # A replacement server session does not execute application SETs.
            $h->{broken}=0;$h->{charset}='server_default';$h->{zone}='+02:00';$h->driver_init;
        }
        return $h->{broken}?0:1;
    }
    sub disconnect {$_[0]{disconnected}++;1}
    package MB1092::Statement;
    sub execute {
        my ($s)=@_;my $h=$s->{db};
        if ($s->{step} && $s->{step}==$h->{at}) {
            return if $h->{fault} eq 'execute_false';
            die "fixture execute failure\n" if $h->{fault} eq 'execute_throw';
            if ($h->{fault} eq 'execute_err') {$s->{error}=1;return '0E0'}
        }
        $h->{charset}=$1 if $s->{sql}=~/\ASET NAMES (\w+)/;
        $h->{zone}='+00:00' if $s->{sql} eq q{SET time_zone = '+00:00'};
        return '0E0';
    }
    sub err {$_[0]{error}}
    sub finish {$_[0]{finished}++;$_[0]{error}=0;die "fixture cleanup failure\n" if $_[0]{db}{cleanup};1}
    sub fetchrow_array {return ('collation_connection','utf8mb4_unicode_ci')}
}
sub conf1092 {
    my ($mode)=@_;return bless {'mysql.MAIN_PROG_DDBNAME'=>'fixture',
        'mysql.MAIN_PROG_DBUSER'=>'fixture','mysql.CHARSET_MODE'=>$mode},'MB1092::Conf';
}
sub connect1092 {
    my ($entry,$mode,%fault)=@_;
    my @opened;
    no warnings qw(redefine once);
    local *DBI::connect=sub {
        die "session SQL must be a connection attribute, not DSN data\n" if $_[1]=~/mariadb_init_command/;
        my $init=$_[4]{mariadb_init_command};
        my $h=MB1092::Handle->new(attrs=>{%{$_[4]}},init=>$init,%fault);$h->driver_init;push @opened,$h;$h};
    my $parent=MB1092::Handle->new(attrs=>{mariadb_auto_reconnect=>0});
    my $owner=bless {conf=>conf1092($mode),logger=>L744->new,charset_mode=>$mode,dbh=>$parent},'Mediabot::DB';
    my ($got,$error);my $ok=eval {
        if ($entry eq 'startup') {$owner=Mediabot::DB->new(conf1092($mode),L744->new);$got=$owner->dbh}
        elsif ($entry eq 'reconnect') {$got=$owner->_connect}
        else {($got,$error)=$owner->connect_isolated_handle}
        1;
    };
    return {owner=>$owner,parent=>$parent,got=>$got,error=>$error,threw=>$ok?0:1,opened=>\@opened};
}

return sub {
    my ($assert) = @_;

    my $db_ok = eval { require Mediabot::DB; 1 };

    # ------------------------------------------------------------------
    # [1] Bornage des timeouts
    # ------------------------------------------------------------------
    if (!$db_ok) {
        $assert->ok(1, 'SKIP: Mediabot::DB non chargeable ici');
    }
    else {
        $assert->ok(Mediabot::DB::_bounded_timeout(undef, 5, 1, 60) == 5, 'timeout: absent -> defaut');
        $assert->ok(Mediabot::DB::_bounded_timeout('0', 5, 1, 60) == 5, 'timeout: 0 -> defaut');
        $assert->ok(Mediabot::DB::_bounded_timeout('12', 5, 1, 60) == 12, 'timeout: valeur gardee');
        $assert->ok(Mediabot::DB::_bounded_timeout('999', 5, 1, 60) == 60, 'timeout: plafonne');
        $assert->ok(Mediabot::DB::_bounded_timeout('abc', 5, 1, 60) == 5, 'timeout: garbage -> defaut');

        my $src = _slurp_744(File::Spec->catfile('Mediabot', 'DB.pm'));
        # mb560-B1: le contrat est « chaque DBI->connect est borné », pas un
        # nombre figé de sites — mb559 a légitimement ajouté la connexion
        # isolée du worker (elle aussi bornée).
        my $connect_sites = () = $src =~ /DBI->connect\(/g;
        my $dsn_sites = () = $src =~ /mariadb_connect_timeout=\$t_connect/g;
        $assert->ok($connect_sites >= 2 && $dsn_sites == $connect_sites,
            "DSN: TOUS les sites de construction bornes ($dsn_sites/$connect_sites)");
        $assert->like($src, qr/mariadb_read_timeout=\$t_read/, 'DSN: read timeout');
        $assert->like($src, qr/mariadb_write_timeout=\$t_write/, 'DSN: write timeout');
    }

    # ------------------------------------------------------------------
    # [2] ensure_connected chronométré
    # ------------------------------------------------------------------
    if ($db_ok) {
        # Chemin rapide: silencieux.
        my $log_fast = L744->new;
        my $fast = bless { dbh => DBH744->new(alive => 1), logger => $log_fast }, 'Mediabot::DB';
        my $h = $fast->ensure_connected;
        $assert->ok($h && !scalar($log_fast->texts), 'rapide: aucun log');

        # Ping lent (>0.25s): ligne niveau 3 avec duree.
        my $log_slow = L744->new;
        my $slow = bless { dbh => DBH744->new(alive => 1, ping_delay => 0.3),
                           logger => $log_slow }, 'Mediabot::DB';
        $slow->ensure_connected;
        my ($l3) = $log_slow->at_level(3);
        $assert->like(($l3->[1] || ''), qr/^DB ping slow: 0\.\d+s/,
            'lent: duree logguee niveau 3');

        # Connexion morte: reconnect tente (echouera sans conf), duree niveau 1.
        my $log_dead = L744->new;
        my $dead = bless { dbh => DBH744->new(alive => 0), logger => $log_dead,
                           conf => undef }, 'Mediabot::DB';
        my $dead_ret = eval { $dead->ensure_connected };
        my @l1 = $log_dead->at_level(1);
        $assert->ok((grep { $_->[1] =~ /DB connection lost/ } @l1) == 1,
            'mort: perte annoncee');
        $assert->ok(!defined($dead_ret),
            'mort: aucun ancien handle mort retourne apres echec');
        $assert->ok((grep { $_->[1] =~ /DB reconnect FAILED in \d+\.\d+s \(ping wait was \d+\.\d+s\)/ } @l1) == 1,
            'mort: echec de reconnexion nomme correctement avec les durees');
    }

    # ------------------------------------------------------------------
    # [3]+[4] Gardes statiques : tick DB unique + wrapper PRIVMSG
    # ------------------------------------------------------------------
    {
        my $src = _slurp_744('mediabot.pl');
        my $tick_db_checks = () = $src =~ /my \$live_dbh = eval \{ \$mediabot->\{db\}->ensure_connected\(\) \};/g;
        $assert->ok($tick_db_checks == 1,
            'tick: un seul health check DB canonique');
        $assert->unlike($src, qr/db_keepalive/,
            'tick: aucun second keepalive redondant');
        $assert->like($src, qr/SLOW PRIVMSG: processing took/,
            'wrapper: message de lenteur present');
        # MB1099: delegation and scalar/list/void preservation now run natively
        # in case 1306, including nested receipt timing and exceptions.
        my $body_defs = () = $src =~ /^sub _on_message_PRIVMSG_body \{/mg;
        $assert->ok($body_defs == 1, 'wrapper: corps defini une seule fois');
        $assert->like($src, qr/tv_interval\(\$t0_548\)/, 'wrapper: chrono HiRes reel');
    }

    # ------------------------------------------------------------------
    # [5] sample.conf
    # ------------------------------------------------------------------
    {
        my $sample = _slurp_744('mediabot.sample.conf');
        for my $k (qw(CONNECT_TIMEOUT READ_TIMEOUT WRITE_TIMEOUT)) {
            $assert->like($sample, qr/^#$k=\d+/m, "sample: $k documente");
        }
    }

    if ($db_ok) {
        require Scalar::Util;
        my @bad;
        for my $entry (qw(startup reconnect isolated)) {
            for my $mode (qw(utf8mb4 latin1 off unknown)) {
                my $x=connect1092($entry,$mode);my $h=$x->{opened}[0];
                my @set=grep {/\ASET /} @{$h->{sql}};
                my $wanted=$mode eq 'latin1'?'latin1':'utf8mb4';
                my $parent_ok=$entry eq 'isolated'
                    ? Scalar::Util::refaddr($x->{owner}->dbh)==Scalar::Util::refaddr($x->{parent})
                    : $x->{got} && Scalar::Util::refaddr($x->{owner}->dbh)==Scalar::Util::refaddr($x->{got});
                push @bad,"$entry/$mode" unless $x->{got} && !$x->{threw} && !$x->{error}
                    && $h->{attrs}{mariadb_auto_reconnect}==($entry eq 'isolated'?0:1) && $h->{init_calls}==1 && $h->{charset} eq $wanted && $h->{zone} eq '+00:00'
                    && @set==($mode eq 'off'?1:4) && $set[-1] eq q{SET time_zone = '+00:00'} && $parent_ok;
            }
        }
        $assert->is(join(',',@bad),'',
            'MB1092 startup, reconnect and isolated handles share confirmed charset/UTC setup and driver initialization while preserving canonical reconnect compatibility');

        {
            my @opened;
            no warnings qw(redefine once);
            local *DBI::connect=sub {
        die "session SQL must be a connection attribute, not DSN data\n" if $_[1]=~/mariadb_init_command/;
        my $init=$_[4]{mariadb_init_command};
                my $h=MB1092::Handle->new(attrs=>{%{$_[4]}},init=>$init);$h->driver_init;push @opened,$h;$h};
            my $owner=Mediabot::DB->new(conf1092('utf8mb4'),L744->new);
            my $old=$owner->dbh;$old->{broken}=1;
            my $metrics=bless {},'MB1092::Metrics';$owner->set_metrics($metrics);
            my $fresh=$owner->ensure_connected;my $again=$owner->ensure_connected;
            $assert->ok($fresh && Scalar::Util::refaddr($fresh)==Scalar::Util::refaddr($old)
                && Scalar::Util::refaddr($again)==Scalar::Util::refaddr($fresh) && @opened==1 && $fresh->{init_calls}==2
                && $fresh->{charset} eq 'utf8mb4' && $fresh->{zone} eq '+00:00'
                && $metrics->{up}==1 && !$metrics->{ok} && !$metrics->{failed},
                'MB1092 a transparent reconnect restores UTF-8/UTC on the same legacy handle without inventing an explicit reconnect metric');
        }
        @bad=();
        for my $entry (qw(startup reconnect isolated)) {
            for my $at (1..4) {
                for my $fault (qw(prepare_false prepare_throw execute_false execute_throw execute_err)) {
                    my $x=connect1092($entry,'utf8mb4',at=>$at,fault=>$fault,cleanup=>1);
                    my $h=$x->{opened}[0];
                    my @set=grep {/\ASET /} @{$h->{sql}};
                    my $safe=$entry eq 'isolated'
                        ? $x->{error} && !$x->{threw} && Scalar::Util::refaddr($x->{owner}->dbh)==Scalar::Util::refaddr($x->{parent})
                        : $entry eq 'startup' ? $x->{threw} : !defined($x->{owner}->dbh) && !$x->{threw};
                    my $clean=!grep {!$_->{finished}} @{$h->{statements}};
                    push @bad,"$entry/$at/$fault" unless !defined($x->{got}) && $h->{disconnected}==1
                        && @set==$at && $safe && $clean;
                }
            }
        }
        $assert->is(join(',',@bad),'',
            'MB1092 every failed prepare/execute/err phase aborts before publication, closes the candidate and retains isolated parent ownership despite throwing cleanup');
        {
            my @opened;my $attempt=0;
            no warnings qw(redefine once);
            local *DBI::connect=sub {my $h=MB1092::Handle->new(attrs=>{%{$_[4]}},
                ($attempt++?():(fault=>'execute_false',at=>4)));push @opened,$h;$h};
            my $dead=MB1092::Handle->new(attrs=>{mariadb_auto_reconnect=>0});$dead->{broken}=1;
            my $owner=bless {conf=>conf1092('utf8mb4'),logger=>L744->new,charset_mode=>'utf8mb4',dbh=>$dead},'Mediabot::DB';
            my $metrics=bless {},'MB1092::Metrics';$owner->set_metrics($metrics);
            my $failed=$owner->ensure_connected;my $down=!defined($owner->dbh) && $metrics->{up}==0;
            my $fresh=$owner->ensure_connected;
            $assert->ok(!defined($failed) && $down && $fresh && @opened==2 && $opened[0]{disconnected}==1
                && $fresh->{zone} eq '+00:00' && $fresh->{charset} eq 'utf8mb4' && $metrics->{up}==1
                && $metrics->{failed}==1 && $metrics->{ok}==1,
                'MB1092 failed session initialization is DB-down, then a clean retry recovers without exposing an uninitialized handle');
        }
        @bad=();
        for my $entry (qw(startup reconnect isolated)) {
            my $x=connect1092($entry,'utf8mb4',cleanup=>1);my $h=$x->{opened}[0];
            push @bad,$entry unless $x->{got} && !$x->{threw} && !$x->{error}
                && !$h->{disconnected} && $h->{zone} eq '+00:00' && $h->{charset} eq 'utf8mb4';
        }
        $assert->is(join(',',@bad),'',
            'MB1092 successful zero-row SET acknowledgements remain success even if later statement cleanup throws');
    }

};
