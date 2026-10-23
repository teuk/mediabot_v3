# t/cases/397_mb161_reminder_starvation_and_first_occurrence.t
# =============================================================================
# Tests des corrections mb161 :
#
#   - B1 : deliverReminders prenait les 3 plus anciens reminders pending
#          (ORDER BY created_at ASC LIMIT 3) PUIS filtrait les [at:TS] non
#          dus en Perl. Si les 3 plus anciens etaient tous programmes dans
#          le futur (daily/weekly re-crees, 'remind in 7d'), ils
#          monopolisaient les slots a chaque appel -> famine : les
#          reminders normaux plus recents n'etaient jamais delivres.
#          Fix : scan jusqu'a 20 rows, filtrer les non-dus, livrer max 3 DUS.
#
#   - B2 : a la creation, un remind daily/weekly n'inserait AUCUN [at:TS]
#          pour la premiere occurrence -> delivre immediatement au prochain
#          message du destinataire au lieu d'attendre l'heure programmee.
#          Fix : calculer la premiere occurrence a la creation (meme logique
#          que la reinsertion dans deliverReminders).
# =============================================================================

use strict;
use warnings;

return sub {
    my ($assert) = @_;

    my $NOW = time();

    # =========================================================================
    # B1 : selection des reminders a livrer
    # =========================================================================

    # Simulation de la selection buggy : LIMIT 3 (created ASC) puis skip
    my $select_buggy = sub {
        my (@db) = @_;
        my @lim3 = @db > 3 ? @db[0..2] : @db;
        return grep {
            my $due = 1;
            $due = ($NOW >= $1) if $_->{message} =~ /\[at:(\d+)\]/;
            $due;
        } @lim3;
    };

    # Simulation de la selection fixee : scan 20, filtre, max 3 dus
    my $select_fixed = sub {
        my (@db) = @_;
        my @cand = @db > 20 ? @db[0..19] : @db;
        my @out;
        for my $r (@cand) {
            if ($r->{message} =~ /\[at:(\d+)\]/) { next if $NOW < $1; }
            push @out, $r;
            last if @out >= 3;
        }
        return @out;
    };

    # -------------------------------------------------------------------------
    # Cas 1 : famine totale — 3 anciens futurs bloquent 2 dus plus recents
    # -------------------------------------------------------------------------
    {
        my @db = (
            { id => 1, message => "[daily:09:00] [at:" . ($NOW+86000) . "] standup" },
            { id => 2, message => "[at:" . ($NOW+600000) . "] check in 7d" },
            { id => 3, message => "[weekly:1:10:00] [at:" . ($NOW+200000) . "] weekly" },
            { id => 4, message => "urgent: call charlie" },
            { id => 5, message => "buy milk" },
        );
        my @b = $select_buggy->(@db);
        my @f = $select_fixed->(@db);
        $assert->(scalar(@b) == 0,
            "B1 REGRESSION-POC: 3 anciens futurs monopolisent -> 0 delivre");
        $assert->(scalar(@f) == 2,
            "B1 FIX: les 2 reminders dus (4,5) sont delivres");
        $assert->($f[0]{id} == 4 && $f[1]{id} == 5,
            "B1 FIX: ordre created_at preserve (4 puis 5)");
    }

    # -------------------------------------------------------------------------
    # Cas 2 : limite anti-flood 3 preservee
    # -------------------------------------------------------------------------
    {
        my @db = map { { id => $_, message => "msg $_" } } 1..6;
        my @f = $select_fixed->(@db);
        $assert->(scalar(@f) == 3,
            "B1 FIX: max 3 reminders par passage (anti-flood preserve)");
        $assert->($f[0]{id} == 1 && $f[2]{id} == 3,
            "B1 FIX: les 3 PLUS ANCIENS dus en premier");
    }

    # -------------------------------------------------------------------------
    # Cas 3 : melange dus / non-dus intercales
    # -------------------------------------------------------------------------
    {
        my @db = (
            { id => 1, message => "[at:" . ($NOW+500) . "] futur1" },
            { id => 2, message => "du tout de suite" },
            { id => 3, message => "[at:" . ($NOW-10) . "] deja du (passe)" },
            { id => 4, message => "[at:" . ($NOW+900) . "] futur2" },
            { id => 5, message => "autre du" },
        );
        my @f = $select_fixed->(@db);
        $assert->(scalar(@f) == 3,
            "B1 FIX: 3 dus parmi les 5 (2 futurs skip)");
        my %got = map { $_->{id} => 1 } @f;
        $assert->($got{2} && $got{3} && $got{5},
            "B1 FIX: ids 2,3,5 delivres (1 et 4 attendent leur heure)");
    }

    # -------------------------------------------------------------------------
    # Cas 4 : compat — pas de tag [at:] du tout (cas le plus courant)
    # -------------------------------------------------------------------------
    {
        my @db = ( { id => 1, message => "simple reminder" } );
        my @b = $select_buggy->(@db);
        my @f = $select_fixed->(@db);
        $assert->(scalar(@b) == 1 && scalar(@f) == 1,
            "B1 compat: reminder sans tag delivre des les 2 versions");
    }

    # =========================================================================
    # B2 : premiere occurrence daily/weekly a la creation
    # =========================================================================

    # Calcul de la premiere occurrence daily (logique du fix)
    my $first_daily_ts = sub {
        my ($hh, $mm, $fake_now) = @_;
        my @now = localtime($fake_now);
        my $today_delta = ($hh * 3600 + $mm * 60)
                        - ($now[2] * 3600 + $now[1] * 60 + $now[0]);
        my $next_secs = $today_delta > 60 ? $today_delta : $today_delta + 86400;
        return $fake_now + $next_secs;
    };

    # Calcul de la premiere occurrence weekly (logique du fix)
    my $first_weekly_ts = sub {
        my ($target_dow, $hh, $mm, $fake_now) = @_;
        my @now     = localtime($fake_now);
        my $cur_dow = $now[6];
        my $days_ahead  = ($target_dow - $cur_dow + 7) % 7;
        my $time_offset = ($hh * 3600 + $mm * 60) - ($now[2] * 3600 + $now[1] * 60 + $now[0]);
        $days_ahead = 7 if $days_ahead == 0 && $time_offset <= 60;
        return $fake_now + ($days_ahead * 86400) + $time_offset;
    };

    # -------------------------------------------------------------------------
    # Cas 5 : daily cree APRES l'heure cible -> premiere livraison demain
    # -------------------------------------------------------------------------
    {
        # Construire un "maintenant" a 14:00:00 precis (aujourd'hui)
        my @now = localtime($NOW);
        my $now_at_14h = $NOW - ($now[2]*3600 + $now[1]*60 + $now[0]) + 14*3600;

        my $ts = $first_daily_ts->(9, 0, $now_at_14h);
        my $delta = $ts - $now_at_14h;
        # De 14:00 a 09:00 le lendemain = 19h
        $assert->($delta == 19*3600,
            "B2 FIX: daily 09:00 cree a 14:00 -> premiere livraison dans 19h (lendemain 09:00)");
        $assert->($ts > $now_at_14h,
            "B2 FIX: [at:TS] strictement futur -> pas de livraison immediate");
    }

    # -------------------------------------------------------------------------
    # Cas 6 : daily cree AVANT l'heure cible -> premiere livraison aujourd'hui
    # -------------------------------------------------------------------------
    {
        my @now = localtime($NOW);
        my $now_at_07h = $NOW - ($now[2]*3600 + $now[1]*60 + $now[0]) + 7*3600;

        my $ts = $first_daily_ts->(9, 0, $now_at_07h);
        my $delta = $ts - $now_at_07h;
        $assert->($delta == 2*3600,
            "B2 FIX: daily 09:00 cree a 07:00 -> premiere livraison dans 2h (aujourd'hui)");
    }

    # -------------------------------------------------------------------------
    # Cas 7 : regression POC — sans [at:], delivrable immediatement
    # -------------------------------------------------------------------------
    {
        my $msg_buggy = "[daily:09:00] standup";        # creation buggy
        my $due_now = ($msg_buggy =~ /\[at:(\d+)\]/) ? ($NOW >= $1 ? 1 : 0) : 1;
        $assert->($due_now == 1,
            "B2 REGRESSION-POC: daily cree sans [at:] est delivrable immediatement");

        my $future = $NOW + 3600;
        my $msg_fixed = "[daily:09:00] [at:$future] standup";   # creation fixee
        my $due_now2 = ($msg_fixed =~ /\[at:(\d+)\]/) ? ($NOW >= $1 ? 1 : 0) : 1;
        $assert->($due_now2 == 0,
            "B2 FIX: daily cree avec [at:futur] n'est PAS delivrable immediatement");
    }

    # -------------------------------------------------------------------------
    # Cas 8 : weekly meme jour, heure pas encore passee -> aujourd'hui
    # -------------------------------------------------------------------------
    {
        my @now = localtime($NOW);
        my $cur_dow = $now[6];
        my $now_at_08h = $NOW - ($now[2]*3600 + $now[1]*60 + $now[0]) + 8*3600;

        # weekly <aujourd'hui> 10:00 cree a 08:00 -> livraison a 10:00 aujourd'hui
        my $ts = $first_weekly_ts->($cur_dow, 10, 0, $now_at_08h);
        my $delta = $ts - $now_at_08h;
        $assert->($delta == 2*3600,
            "B2 FIX: weekly <today> 10:00 cree a 08:00 -> livraison dans 2h (aujourd'hui)");
    }

    # -------------------------------------------------------------------------
    # Cas 9 : weekly meme jour, heure passee -> semaine suivante
    # -------------------------------------------------------------------------
    {
        my @now = localtime($NOW);
        my $cur_dow = $now[6];
        my $now_at_15h = $NOW - ($now[2]*3600 + $now[1]*60 + $now[0]) + 15*3600;

        # weekly <aujourd'hui> 10:00 cree a 15:00 -> dans 7j - 5h
        my $ts = $first_weekly_ts->($cur_dow, 10, 0, $now_at_15h);
        my $delta = $ts - $now_at_15h;
        $assert->($delta == 7*86400 - 5*3600,
            "B2 FIX: weekly <today> 10:00 cree a 15:00 -> semaine suivante (7j - 5h)");
    }

    # -------------------------------------------------------------------------
    # Cas 10 : weekly autre jour -> nombre de jours correct
    # -------------------------------------------------------------------------
    {
        my @now = localtime($NOW);
        my $cur_dow = $now[6];
        my $target  = ($cur_dow + 3) % 7;   # dans 3 jours
        my $now_at_12h = $NOW - ($now[2]*3600 + $now[1]*60 + $now[0]) + 12*3600;

        my $ts = $first_weekly_ts->($target, 12, 0, $now_at_12h);
        my $delta = $ts - $now_at_12h;
        $assert->($delta == 3*86400,
            "B2 FIX: weekly J+3 12:00 cree a 12:00 -> exactement 3 jours");
    }

    # -------------------------------------------------------------------------
    # Cas 11 : coherence creation vs reinsertion — meme heure cible
    # -------------------------------------------------------------------------
    {
        # La reinsertion dans deliverReminders utilise la meme formule daily :
        # next_secs = today_delta > 60 ? today_delta : today_delta + 86400
        # On verifie que les deux calculs donnent le meme [at:] pour le
        # meme instant — garantit que la 1ere livraison et les suivantes
        # arrivent a la meme heure.
        my @now = localtime($NOW);
        my $now_at_10h = $NOW - ($now[2]*3600 + $now[1]*60 + $now[0]) + 10*3600;

        my $creation_ts    = $first_daily_ts->(9, 30, $now_at_10h);
        # Reinsertion (formule deliverReminders, identique)
        my @rn = localtime($now_at_10h);
        my $rd = (9*3600 + 30*60) - ($rn[2]*3600 + $rn[1]*60 + $rn[0]);
        my $reinsert_ts = $now_at_10h + ($rd > 60 ? $rd : $rd + 86400);

        $assert->($creation_ts == $reinsert_ts,
            "B2 coherence: creation et reinsertion calculent le meme [at:TS]");
    }


    # MB926: execute the actual delivery functions on two SQLite connections.
    # The second connection changes pending state after the first read.
    require JSON::PP;
    my $probe=<<'MB926_NATIVE';
use strict;
use warnings;
use utf8;
BEGIN {*CORE::GLOBAL::time=sub () {1800000000}}
use POSIX ();
BEGIN {$ENV{TZ}='UTC'; POSIX::tzset()}
use DBI;
use File::Temp qw(tempdir);
use JSON::PP;
use Mediabot::CommunityState;
use Mediabot::UserCommands;
use Mediabot::Channel;
{
    package MB926::Log;
    sub log {my ($s,@v)=@_;push @{$s->{lines}},\@v;1}
    package MB926::DBI;our @ISA=('DBI');
    package MB926::DBI::db;our @ISA=('DBI::db');
    sub prepare {
        my ($s,$sql,@rest)=@_;my $p=$s->{private_mb926};
        push @{$p->{sql}},$sql if $p;
        my $actual=$sql;
        $actual =~ s/UPDATE REMINDERS/UPDATE MB926_MISSING/
            if $p && $p->{fail_prepare} && $sql=~/UPDATE REMINDERS SET delivered = 1/;
        my $sth=$s->SUPER::prepare($actual,@rest);
        $sth->{private_mb926}={trace=>$p,sql=>$sql} if $sth && $p;
        return $sth;
    }
    package MB926::DBI::st;our @ISA=('DBI::st');
    sub execute {
        my ($s,@bind)=@_;my $p=$s->{private_mb926};
        if ($p) {
            push @{$p->{trace}{binds}},[$p->{sql},@bind];
            $p->{trace}{before_claim}->($bind[0])
                if $p->{trace}{before_claim} && $p->{sql}=~/UPDATE REMINDERS SET delivered = 1 WHERE id_reminder/;
        }
        my $ret=$s->SUPER::execute(@bind);
        push @{$p->{trace}{executed}},[$p->{sql},defined($ret)?"$ret":undef,0+$s->SUPER::rows] if $p;
        return $ret;
    }
    sub finish {
        my ($s)=@_;my $p=$s->{private_mb926};
        push @{$p->{trace}{finished}},$p->{sql} if $p;
        return $s->SUPER::finish;
    }
}
$INC{'MB926/DBI.pm'}=__FILE__;
sub run {
    my (%a)=@_;
    my $dir=tempdir(CLEANUP=>1);
    my $dsn="dbi:SQLite:dbname=$dir/reminders.sqlite";
    my $connect=sub {DBI->connect($dsn,'','',{RootClass=>'MB926::DBI',RaiseError=>0,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1})};
    my $db=$connect->();my $peer_db=$connect->();
    $db->do(q{CREATE TABLE REMINDERS(id_reminder INTEGER PRIMARY KEY,id_channel INTEGER,from_nick TEXT,to_nick TEXT,message TEXT,created_at TEXT DEFAULT 'stored-999',delivered INTEGER DEFAULT 0)});
    my @ids=(10,21,35,77);
    my @rows;
    for my $i (0..($a{count}//4)-1) {
        my $id=$ids[$i];
        my $prefix=$a{daily} ? '[daily:09:00] [at:100] '
            : $a{weekly} ? '[weekly:1:09:00] [at:100] '
            : $a{future} && $i<3 ? '[at:1800000600] ' : '';
        push @rows,[$id,1,'Sender','alice',$prefix."été message $id",sprintf('stored-%03d',$id),0];
    }
    if ($a{scan_limit}) {
        @rows=map {[$_,1,'Sender','alice','[at:1800000600] future',sprintf('stored-%03d',$_),0]} 1..20;
        push @rows,[21,1,'Sender','alice','outside scan','stored-021',0];
    }
    push @rows,([200,2,'Sender','alice','other channel','stored-200',0],
        [201,1,'Sender','bob','other recipient','stored-201',0],
        [202,1,'Sender','alice','already delivered','stored-202',1],
        [203,1,'Sender','alice','cancelled','stored-203',2]);
    $db->do('INSERT INTO REMINDERS VALUES(?,?,?,?,?,?,?)',undef,@$_) for @rows;
    $db->do(q{CREATE TRIGGER reject_claim BEFORE UPDATE ON REMINDERS WHEN OLD.id_reminder=21 BEGIN SELECT RAISE(ABORT,'private claim refusal'); END})
        if $a{execute_error};
    my (@sent,@warnings,@logs);
    my $make_bot=sub {
        my ($h,$label)=@_;
        return {dbh=>$h,label=>$label,channels=>{'#test'=>Mediabot::Channel->new({id=>1,name=>'#test',dbh=>$h})},
            logger=>bless({lines=>[]},'MB926::Log')};
    };
    my $bot=$make_bot->($db,'owner');my $peer=$make_bot->($peer_db,'peer');
    my $method=$a{entry} eq 'module' ? \&Mediabot::CommunityState::deliverReminders : \&Mediabot::UserCommands::deliverReminders;
    my $injected=0;
    my $trace={sql=>[],binds=>[],executed=>[],finished=>[],fail_prepare=>$a{prepare_error}?1:0};
    my $peer_trace={sql=>[],binds=>[],executed=>[],finished=>[]};
    $trace->{before_claim}=sub {
        my ($id)=@_;
        return if $injected || !defined($a{race});
        return if $a{race} ne 'competing' && $id!=($a{at}//21);
        $injected=1;
        if ($a{race} eq 'competing') {
            $peer_db->{private_mb926}=$peer_trace;
            $method->($peer,'ALICE','#test');
            $peer_db->{private_mb926}=undef;
        } elsif ($a{race} eq 'delete') {
            $peer_db->do('DELETE FROM REMINDERS WHERE id_reminder=?',undef,$id);
        } else {
            my $state=$a{race} eq 'cancel' ? 2 : 1;
            $peer_db->do('UPDATE REMINDERS SET delivered=? WHERE id_reminder=?',undef,$state,$id);
        }
    };
    $db->{private_mb926}=$trace;
    no warnings qw(redefine once);
    local *Mediabot::UserCommands::botPrivmsg=sub {
        my ($b,$channel,$text)=@_;
        my $saved=$peer_db->{private_mb926};$peer_db->{private_mb926}=undef;
        my $states=$peer_db->selectall_arrayref('SELECT id_reminder,delivered FROM REMINDERS ORDER BY id_reminder');
        $peer_db->{private_mb926}=$saved;
        push @sent,[$b->{label},$channel,$text,$states];
        die "private output refusal\n" if $a{output_throw};
        return $a{output_false}?0:1;
    };
    local $SIG{__WARN__}=sub {push @warnings,@_};
    my $ok=eval {$method->($bot,'ALICE','#test');1};
    my $error=$ok?'':"$@";
    $db->{private_mb926}=undef;
    delete $trace->{before_claim};
    my $out={sent=>\@sent,warnings=>\@warnings,error=>$error,injected=>$injected,
        rows=>$db->selectall_arrayref('SELECT * FROM REMINDERS ORDER BY id_reminder'),
        logs=>$bot->{logger}{lines},peer_logs=>$peer->{logger}{lines},
        trace=>$trace,peer_trace=>$peer_trace};
    $db->disconnect;$peer_db->disconnect;
    return $out;
}
my %out;
for my $entry (qw(module facade)) {
    for my $race (qw(cancel delivered delete)) {
        for my $at (10,21,35) {
            $out{race}{$entry}{$race}{$at}=run(entry=>$entry,race=>$race,at=>$at);
        }
    }
    for my $kind (qw(daily weekly)) {
        $out{recurring_cancel}{$entry}{$kind}=run(entry=>$entry,count=>1,$kind=>1,race=>'cancel',at=>10);
    }
    $out{competing}{$entry}=run(entry=>$entry,race=>'competing');
    for my $kind (qw(normal one future scan_limit daily weekly prepare_error execute_error output_false output_throw)) {
        my %args=(entry=>$entry);
        $args{count}=1 if $kind=~/^(one|daily|weekly)$/;
        $args{$kind}=1 unless $kind eq 'normal' || $kind eq 'one';
        $out{nominal}{$entry}{$kind}=run(%args);
    }
}
print JSON::PP->new->canonical->utf8->encode(\%out);
MB926_NATIVE
    open my $child,'-|',$^X,'-I.','-It/lib','-e',$probe
        or do {$assert->(0,"MB926 native child could not start: $!");return};
    my $raw=do {local $/;<$child>};close $child;
    my $rc=$?;my $data=eval {JSON::PP::decode_json($raw)};
    $assert->($rc==0 && ref($data) eq 'HASH',
        'MB926 native two-connection reminder probe returns JSON');
    return unless $rc==0 && ref($data) eq 'HASH';
    my $same=sub {JSON::PP->new->canonical->encode($_[0]) eq JSON::PP->new->canonical->encode($_[1])};
    my $states=sub {+{map {$_->[0]=>$_->[-1]} @{$_[0]{rows}}}};
    my $sent_ids=sub {[map {my ($id)=$_->[2]=~/message (\d+)\z/;defined($id)?0+$id:-1} @{$_[0]{sent}}]};
    my $claim=sub {$_[0]=~/UPDATE REMINDERS SET delivered = 1 WHERE id_reminder/};
    my $claims=sub {[grep {$claim->($_->[0])} @{$_[0]{trace}{executed}}]};
    my $finished=sub {scalar grep {$claim->($_)} @{$_[0]{trace}{finished}}};
    my $unrelated=sub {
        my ($x)=@_;my $s=$states->($x);
        return $same->([@$s{200,201,202,203}],[0,0,1,2])
            && !$x->{error} && !@{$x->{warnings}};
    };
    my @bad;my $count=0;
    for my $entry (qw(module facade)) {
        for my $race (qw(cancel delivered delete)) {
            for my $at (10,21,35) {
                my $x=$data->{race}{$entry}{$race}{$at};my $s=$states->($x);
                my @wanted=grep {$_!=$at} (10,21,35);
                my $correct=$race eq 'delete' ? !exists($s->{$at})
                    : $s->{$at}==($race eq 'cancel'?2:1);
                my $zero=scalar grep {defined($_->[1]) && $_->[1] eq '0E0' && $_->[2]==0} @{$claims->($x)};
                push @bad,"$entry/$race/$at" unless $x->{injected}==1 && $unrelated->($x)
                    && $correct && $same->($sent_ids->($x),\@wanted) && $s->{77}==0
                    && @{$claims->($x)}==3 && $zero==1 && $finished->($x)==3;
                $count++;
            }
        }
    }
    $assert->($count==18 && !@bad,
        'MB926 stale snapshots cannot send or overwrite cancelled/delivered/deleted reminders; zero-row claims finish'
        . (@bad?': '.join(',',@bad):''));
    @bad=();
    for my $entry (qw(module facade)) {
        my $x=$data->{competing}{$entry};
        push @bad,"$entry/two-readers" unless $unrelated->($x) && $x->{injected}==1
            && $same->($sent_ids->($x),[10,21,35])
            && $same->([map {$_->[0]} @{$x->{sent}}],[qw(peer peer peer)])
            && @{$claims->($x)}==3 && $finished->($x)==3
            && !grep {$_->[2]!=0} @{$claims->($x)};
        for my $kind (qw(daily weekly)) {
            my $r=$data->{recurring_cancel}{$entry}{$kind};
            my $s=$states->($r);
            push @bad,"$entry/$kind" unless $unrelated->($r) && $r->{injected}==1
                && !@{$r->{sent}} && $s->{10}==2 && @{$r->{rows}}==5
                && @{$claims->($r)}==1 && $finished->($r)==1;
        }
    }
    $assert->(!@bad,
        'MB926 two actual readers deliver each selected reminder once and cancelled recurrences do not reappear'
        . (@bad?': '.join(',',@bad):''));
    @bad=();
    for my $entry (qw(module facade)) {
        for my $kind (qw(normal one future scan_limit daily weekly prepare_error execute_error output_false output_throw)) {
            my $x=$data->{nominal}{$entry}{$kind};my $s=$states->($x);
            my $ids=$kind eq 'scan_limit' || $kind eq 'prepare_error' ? []
                : $kind eq 'future' ? [77] : $kind eq 'execute_error' ? [10,35]
                : $kind=~/^(one|daily|weekly|output_throw)$/ ? [10] : [10,21,35];
            my $ok=$same->($sent_ids->($x),$ids) && !$x->{injected} && !@{$x->{warnings}}
                && $same->([@$s{200,201,202,203}],[0,0,1,2])
                && $x->{error} eq ($kind eq 'output_throw'?"private output refusal\n":'');
            for my $sent (@{$x->{sent}}) {
                my ($id)=$sent->[2]=~/message (\d+)\z/;
                my %at_send=map {$_->[0]=>$_->[1]} @{$sent->[3]};
                $ok &&= $sent->[0] eq 'owner' && $sent->[1] eq '#test'
                    && defined($id) && $at_send{$id}==1;
                my $tag=$kind eq 'daily'?' [daily 09:00]'
                    :$kind eq 'weekly'?' [weekly Mon 09:00]':'';
                my $want=sprintf('ALICE: reminder from Sender (stored-%03d)%s: ', $id//0,$tag)
                    ."\x{e9}t\x{e9} message ".($id//0);
                $ok &&= $sent->[2] eq $want;
            }
            my %sent=map {$_=>1} @$ids;
            for my $id (10,21,35,77) {
                next unless exists $s->{$id};
                $ok &&= $s->{$id}==($sent{$id}?1:0);
            }
            if ($kind eq 'daily' || $kind eq 'weekly') {
                my @new=grep {$_->[0]>203} @{$x->{rows}};
                $ok &&= @new==1 && $new[0][1]==1 && $new[0][2] eq 'Sender'
                    && $new[0][3] eq 'alice' && $new[0][-1]==0;
                my ($at)=$new[0][4]=~/\[at:(\d+)\]/;
                $ok &&= defined($at) && $at>1800000000;
            }
            my $n=$kind eq 'scan_limit'?0 : $kind eq 'prepare_error'?0
                : $kind=~/^(one|daily|weekly|future|output_throw)$/?1:3;
            $ok &&= $finished->($x)==$n;
            push @bad,"$entry/$kind" unless $ok;
        }
    }
    $assert->(!@bad,
        'MB926 real nominal delivery keeps Unicode, due filtering, limits, recurrence, SQL refusal and pre-send marking'
        . (@bad?': '.join(',',@bad):''));
};
