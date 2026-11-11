# t/cases/761_mb571_archive_precommit_hardening.t
# =============================================================================
# mb571 — hardening pre-commit des rounds mb565..mb570 :
#   - archivage scheduler forke avec DB isolee, jamais synchrone dans IO::Async ;
#   - verification d'identite exacte + MAX_PER_RUN strict ;
#   - purge legacy fail-closed quand l'archive SQL est configuree ;
#   - normalize: un ADD echoue interdit tous les DROP projetes ;
#   - documentation honnette: seul onthisday est archive-aware aujourd'hui.
# =============================================================================
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_761 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;
    my $mod  = _slurp_761(File::Spec->catfile('Mediabot', 'Mediabot.pm'));
    my $main = _slurp_761('mediabot.pl');
    my $norm = _slurp_761(File::Spec->catfile('tools', 'normalize_channel_log_indexes.pl'));
    my $sample = _slurp_761('mediabot.sample.conf');

    $assert->like($main, qr/start_channel_log_archive_async/,
        'scheduler appelle le lanceur async');
    $assert->unlike($main, qr/\$mediabot->archive_channel_log\(\)/,
        'scheduler ne lance jamais le gros SQL synchroniquement');

    my ($async) = $mod =~ /(sub start_channel_log_archive_async \{.*?\n\})/s;
    $assert->ok(defined $async, 'lanceur async present');
    $assert->like($async // '', qr/fork\(\)/, 'worker forke');
    $assert->like($async // '', qr/connect_isolated_handle/, 'connexion DB isolee');
    $assert->like($async // '', qr/InactiveDestroy/, 'handles parents proteges');
    $assert->like($async // '', qr/watch_process/, 'processus reap par IO::Async');
    $assert->like($async // '', qr/POSIX::_exit/, 'sortie enfant sans destructeurs parents');

    my ($arch) = $mod =~ /(sub archive_channel_log \{.*?\n\})/s;
    $assert->like($arch // '', qr/JOIN CHANNEL_LOG live/, 'verification compare archive et vif');
    $assert->like($arch // '', qr/publictext/, 'verification inclut le contenu');
    $assert->like($arch // '', qr/my \$remaining = \$max_run - \$total/,
        'MAX_PER_RUN strict sur le dernier lot');

    my ($purge) = $mod =~ /(sub purge_channel_log \{.*?\n\})/s;
    $assert->like($purge // '', qr/CHANNEL_LOG_ARCHIVE_DBNAME/,
        'purge legacy refusee quand archive configuree');

    $assert->like($norm, qr/if \(\$verb eq 'DROP' && \$add_failed\)/,
        'normalize saute les DROP projetes apres echec ADD');
    # mb584: le pipeline traite desormais vif + archive — le code retour
    # agrege les echecs des deux tables (run_table retourne $failed).
    $assert->like($norm, qr/exit\(\$total_failed \? 2 : 0\)/,
        'normalize retourne non-zero si une action echoue');

    $assert->like($sample, qr/Other lifetime commands\/achievements still read only\n# the live table/,
        'sample documente la fenetre historique des autres commandes');
    # Execute the exact shutdown/launch routines in an isolated package. Process
    # operations are injectable here only; production has no test-only switches.
    my ($stop)=$mod =~ /(sub _stop_channel_log_archive_worker \{.*?\n\})/s;
    die 'missing archive stop routine' unless $stop && $async;
    {
        package MB1226::Archive;
        use POSIX qw(WNOHANG);
        use Errno qw(ECHILD EINTR EINVAL);
        use Time::HiRes ();
        use subs qw(waitpid kill usleep fork);
        our (@waits,@signals,@flags,$sleeps,$native);
        sub waitpid {
            push @flags,$_[1];die 'blocking wait forbidden' unless $_[1];
            return CORE::waitpid($_[0],$_[1]) if $native;
            my $row=shift(@waits)||[0,0];$!=$row->[1];return $row->[0];
        }
        sub kill {push @signals,$_[0];return $native?CORE::kill($_[0],$_[1]):1}
        sub usleep {$sleeps++;Time::HiRes::usleep($_[0]) if $native}
        sub fork {123}
        package MB1226::Log;
        sub log {push @{$_[0]{rows}},$_[2]}
        package MB1226::Loop;
        sub unwatch_process {push @{$_[0]{removed}},$_[1]}
        sub watch_process {$_[0]{callback}=$_[2];die 'watch rejected' if $_[0]{reject};1}
        package MB1226::Conf;
        sub get {'fixture_archive'}
    }
    { no warnings 'redefine';
      eval "package MB1226::Archive; use POSIX qw(WNOHANG); use subs qw(waitpid kill usleep fork); $stop\n$async\n1;" or die $@; }
    for my $case (
        ['already collected',[[123,0]],0,1,[]],
        ['ECHILD',[[-1,Errno::ECHILD()]],0,1,[]],
        ['TERM',[[0,0],[123,0]],0,1,['TERM']],
        ['EINTR',[[-1,Errno::EINTR()],[0,0],[123,0]],0,1,['TERM']],
        ['wait error',[[-1,Errno::EINVAL()]],0,0,[]],
        ['unconfirmed',[],0,0,['TERM','KILL']],
        ['immediate KILL',[[0,0],[123,0]],1,1,['KILL']],
    ) {
        my ($name,$waits,$immediate,$expected,$signals)=@$case;
        @MB1226::Archive::waits=@$waits;@MB1226::Archive::signals=();@MB1226::Archive::flags=();$MB1226::Archive::sleeps=0;
        my $bot=bless {_channel_log_archive_pid=>123,_channel_log_archive_started=>42,
            loop=>bless({},'MB1226::Loop'),logger=>bless({},'MB1226::Log')},'MB1226::Archive';
        my $ok=$bot->_stop_channel_log_archive_worker($immediate);
        $assert->ok($ok==$expected,"$name: explicit collection outcome");
        $assert->ok(join(',',@MB1226::Archive::signals) eq join(',',@$signals),"$name: signals only after ownership check");
        $assert->ok($expected ? !exists($bot->{_channel_log_archive_pid}) && !exists($bot->{_channel_log_archive_started})
            : $bot->{_channel_log_archive_pid}==123 && $bot->{_channel_log_archive_started}==42,
            "$name: unconfirmed ownership retained, confirmed state cleared");
        $assert->ok(@MB1226::Archive::flags<=21 && $MB1226::Archive::sleeps<=20,
            "$name: polling stays finite and nonblocking");
        $assert->ok($expected ? @{$bot->{loop}{removed}||[]}==1 : @{$bot->{logger}{rows}||[]}==1,
            "$name: confirmed watcher detached or uncertainty diagnosed");
    }
    # Real child behaviour, with readiness handshake and no event-loop progress.
    require IO::Select;
    for my $ignore (0,1) {
        pipe(my $ready,my $notify) or die $!;
        my $pid=CORE::fork();die $! unless defined $pid;
        if (!$pid) {
            close $ready;$SIG{TERM}=$ignore?'IGNORE':'DEFAULT';syswrite($notify,'R');
            while (1) {Time::HiRes::sleep(1)}
        }
        close $notify;
        unless (IO::Select->new($ready)->can_read(3)) {CORE::kill('KILL',$pid);CORE::waitpid($pid,0);die 'readiness timeout'}
        sysread($ready,my $byte,1);close $ready;
        my $bot=bless {_channel_log_archive_pid=>$pid,_channel_log_archive_started=>42},'MB1226::Archive';
        local $MB1226::Archive::native=1;
        my $ok=$bot->_stop_channel_log_archive_worker;
        my $seen=CORE::waitpid($pid,POSIX::WNOHANG());my $reaped=$seen==-1 && $!{ECHILD};
        if ($seen==0) {CORE::kill('KILL',$pid);CORE::waitpid($pid,0)}
        $assert->ok($ok && $reaped,"native ignore_TERM=$ignore: child physically collected");
        $assert->ok(!$bot->{_channel_log_archive_pid},"native ignore_TERM=$ignore: ownership retired");
    }
    @MB1226::Archive::waits=([0,0],[123,0]);
    my $bot=bless {conf=>bless({},'MB1226::Conf'),loop=>bless({reject=>1},'MB1226::Loop'),
        logger=>bless({},'MB1226::Log')},'MB1226::Archive';
    $assert->ok(!$bot->start_channel_log_archive_async && !$bot->{_channel_log_archive_pid},
        'rejected watcher uses bounded collection and retains launch refusal');
    my $late=$bot->{loop}{callback};
    $bot->{_channel_log_archive_pid}=456;$bot->{_channel_log_archive_started}=99;
    $late->(123,0);
    $assert->ok($bot->{_channel_log_archive_pid}==456 && $bot->{_channel_log_archive_started}==99
        && !$bot->{_archive_last_run},'obsolete watcher cannot clear successor or invent status');
    $assert->like($mod,qr/_stop_channel_log_archive_worker\(\$self\);/,
        'final exit delegates archive collection to the tested routine');

};
