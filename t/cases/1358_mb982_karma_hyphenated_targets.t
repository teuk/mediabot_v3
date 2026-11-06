use strict;
use warnings;
use Test::More;
use DBI;
use File::Temp qw(tempdir);
BEGIN { *CORE::GLOBAL::time = sub { 1_900_000_000 } }
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::Partyline::Commands ();
use Mediabot::DCC ();
use Mediabot::IRC::Target ();
use Mediabot::Spark::Identity ();
use Mediabot::Update ();

{
    package MB982::DBI; our @ISA=('DBI');
    package MB982::DBI::db; our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        # Translate dialect only; the real handlers execute all writes/reads.
        $sql=~s/ON DUPLICATE KEY UPDATE score = score \+ \?/ON CONFLICT(id_channel,nick) DO UPDATE SET score = score + ?/;
        $sql=~s/INSERT IGNORE INTO KARMA_LOG/INSERT OR IGNORE INTO KARMA_LOG/;
        $sql=~s/NOW\(\)/CURRENT_TIMESTAMP/g;
        return $db->SUPER::prepare($sql,@rest);
    }
    package MB982::DBI::st; our @ISA=('DBI::st');
    package MB982::Bot; our @ISA=('Mediabot');
    sub gethChannelsNicksOnChan { @{$_[0]{fixture_nicks}} }
    package MB982::Channel; sub get_id { $_[0]{id} // 1 }
    package MB982::IRC; sub nick_folded { 'Bob' }
    package MB982::Stream; sub write { $_[0]{text} .= $_[1]; 1 }
    package MB982::Log; sub log {1}
    package MB982::Metrics; sub inc {$_[0]{counts}{$_[1]}++;1}
    package MB982::Achievements;
    sub bump_progress { $_[0]{given}{$_[2]} += $_[4]; $_[0]{given}{$_[2]} }
    sub progress {$_[0]{given}{$_[2]}//0}
    sub check_karma {push @{$_[0]{calls}},[@_[1..5]];1}

    package MB1126::Bot; our @ISA=('Mediabot');
    sub isIgnored {$_[4] eq 'ignored Bob++'}
    sub observe_public_word {}
    sub getMessageNickIdentHost {return (($_[1] // ''),'ident','host')}
    sub observe_channel_event {}
    sub is_hailo_excluded_nick {0}
    sub hailo_observe_public_line {}
    sub hailo_record_activity {}
    sub hailo_should_chatter {0}
    sub checkResponder {100}
    sub getIdChansetList {undef}
    sub logBotAction {}
    sub displayUrlTitle {}
    sub mbCommandPrivate {}
    sub mbCommandPublic {
        my ($bot,$message,$channel,$nick,$trigger,$command,@args)=@_;
        return unless $command eq 'karma';
        my $ctx=Mediabot::Context->new(bot=>$bot,nick=>$nick,channel=>$channel,
            command=>$command,args=>\@args);
        $ctx->{_user_fetched}=1;
        $bot->command_registry->handler_for($command,'public')->($ctx);
    }
    package MB1126::Conf;
    sub get {
        my (undef,$key)=@_;
        return '!' if $key eq 'main.MAIN_PROG_CMD_CHAR';
        return 'Relay' if $key eq 'main.BOT_NICKS';
        return;
    }
    package MB1126::IRC;
    sub nick {'Mediabot'}
    sub nick_folded {'mediabot'}
    package MB1126::Exclusion;
    sub classify_public_line {
        my (undef,%args)=@_;
        return {excluded=>($args{nick} eq 'Excluded'),reason=>'declared_bot'};
    }
}
$INC{'MB982/DBI.pm'}=__FILE__;
my $tmp=tempdir(CLEANUP=>1);my $serial=0;
my (@wire,@warnings);
no warnings qw(redefine once);
local *Mediabot::Helpers::botNotice=sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::Helpers::botPrivmsg=sub {push @wire,['public',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botNotice=sub {goto &Mediabot::Helpers::botNotice};
local *Mediabot::UserCommands::botPrivmsg=sub {goto &Mediabot::Helpers::botPrivmsg};
local $SIG{__WARN__}=sub {push @warnings,@_};
my $long='Long-Nick-'.('x'x22);
my @targets=('Alice-Bob','Alice--Bob','Bob-','Bob--','PlainNick',$long);
my @present=(@targets,qw(Bob Carol Dave Te[u]K));

sub setup_1358 {
    my $dsn='dbi:SQLite:dbname='.$tmp.'/'.++$serial.'.sqlite';
    my $db=DBI->connect($dsn,'','',{RootClass=>'MB982::DBI',
        RaiseError=>1,PrintError=>0,AutoCommit=>1});
    my $peer=DBI->connect($dsn,'','',{RaiseError=>1,PrintError=>0,AutoCommit=>1});
    $peer->begin_work; # MB1058: fixture seed only, before native operations.
    $peer->do('CREATE TABLE KARMA(id_channel INTEGER,nick TEXT,score INTEGER,PRIMARY KEY(id_channel,nick))');
    $peer->do('CREATE TABLE KARMA_LOG(id_channel INTEGER,nick TEXT,delta INTEGER,from_nick TEXT,score INTEGER,ts TEXT)');
    for my $name (@present) {
        $peer->do('INSERT INTO KARMA VALUES(1,?,10)',undef,lc $name);
        $peer->do('INSERT INTO KARMA VALUES(2,?,90)',undef,lc $name);
    }
    $peer->commit;
    my $bot=Mediabot->new({dbh=>$db});bless $bot,'MB982::Bot';
    $bot->{fixture_nicks}=[@present];
    $bot->{channels}{'#test'}=bless {},'MB982::Channel';
    $bot->{logger}=bless {},'MB982::Log';
    $bot->{metrics}=bless {counts=>{}},'MB982::Metrics';
    $bot->{achievements}=bless {calls=>[],given=>{}},'MB982::Achievements';
    $bot->{_karma_watch}={Watcher=>[map {lc} @present]};
    return ($bot,$peer);
}
sub invoke_1358 {
    my ($entry,$bot,$voter,$op,$target,$text,$channel)=@_;
    $channel //= '#test';
    @wire=();@warnings=();
    my $ok=eval {
        if ($entry eq 'registry') {
            my $ctx=Mediabot::Context->new(bot=>$bot,nick=>$voter,channel=>$channel,
                command=>'karma',args=>[$op,$target]);
            $ctx->{_user_fetched}=1;
            $bot->command_registry->handler_for('karma','public')->($ctx);
        } else {
            no strict 'refs';
            &{"${entry}::processKarma"}($bot,$voter,$channel,defined($text)?$text:"$target$op");
        }
        1;
    };
    return $ok?'':$@;
}
sub score_1358 {$_[0]->selectrow_array('SELECT score FROM KARMA WHERE id_channel=1 AND nick=?',undef,lc $_[1])}
sub notices_1358 {[map {$_->[2]} grep {$_->[0] eq 'notice'} @wire]}

for my $entry (qw(Mediabot::Karma registry)) {
    for my $op ($entry eq 'registry' ? ('+','-','++','--') : ('++','--')) {
        for my $target ($entry eq 'registry' ? ('Alice-Bob') : @targets) {
            my ($bot,$peer)=setup_1358();my $label="$entry $target $op";
            my $delta=$op=~/\+/?1:-1;
            is(invoke_1358($entry,$bot,'Voter',$op,$target),'',"$label: real handler completes");
            is(score_1358($peer,$target),10+$delta,"$label: full intended target changes");
            is($peer->selectrow_array('SELECT COUNT(*) FROM KARMA WHERE id_channel=1 AND score!=10'),1,
                "$label: no suffix or unrelated nick is changed");
            is($peer->selectrow_array('SELECT COUNT(*) FROM KARMA WHERE id_channel=2 AND score!=90'),0,
                "$label: another channel is untouched");
            is_deeply($peer->selectall_arrayref('SELECT nick,delta,from_nick,score FROM KARMA_LOG'),
                [[lc($target),$delta,'Voter',10+$delta]],"$label: persisted history records the exact target");
            is($bot->{_karma_log}{'#test'}[0]{nick},lc($target),"$label: memory history agrees");
            is($bot->{achievements}{calls}[0][0],lc($target),"$label: achievement hook receives the intended target");
            is(scalar @{$bot->{achievements}{calls}},1,"$label: one achievement callback");
            is($bot->{metrics}{counts}{mediabot_karma_votes_total},1,"$label: one vote attempt");
            like(join(' ',@{notices_1358()}),qr/\[karmawatch\] \Q@{[lc $target]}\E received/,
                "$label: watchers are notified for the same target");
            is(scalar @warnings,0,"$label: no warning escapes");
        }
    }
}

for my $entry ('Mediabot::Karma') {
    for my $text ('Absent-Bob++','Absent-Bob--',('X'x35).'Bob++','Alice-Bob+++','Alice-Bob--again') {
        my ($bot,$peer)=setup_1358();
        is(invoke_1358($entry,$bot,'Voter','++','Alice-Bob',$text),'',"$entry $text: rejected token completes");
        is($peer->selectrow_array('SELECT COUNT(*) FROM KARMA WHERE score NOT IN(10,90)'),0,
            "$entry $text: no suffix fallback or overlong partial target");
        is($peer->selectrow_array('SELECT COUNT(*) FROM KARMA_LOG'),0,"$entry $text: no false history");
        is(scalar @wire,0,"$entry $text: no false announcement");
    }
    for my $voter ('Alice-Bob','ALICE-BOB','Alice-Bob[away]') {
        my ($bot,$peer)=setup_1358();
        is(invoke_1358($entry,$bot,$voter,'++','Alice-Bob'),'',"$entry $voter: self-vote handler completes");
        is(score_1358($peer,'Bob'),10,"$entry $voter: rejected self-vote cannot mutate Bob");
        is(score_1358($peer,'Alice-Bob'),10,"$entry $voter: self-vote stays blocked");
        is($peer->selectrow_array('SELECT COUNT(*) FROM KARMA_LOG'),0,"$entry $voter: no self-vote persisted");
        like(join(' ',map {$_->[2]} @wire),qr/can't change your own karma/,
            "$entry $voter: original self-vote response retained");
    }
}

{
    my ($bot,$peer)=setup_1358();
    is(invoke_1358('registry',$bot,'Voter','+','Alice-Bob'),'', 'explicit compound vote starts cooldown');
    invoke_1358('Mediabot::Karma',$bot,'Voter','++','ALICE-BOB');
    is(score_1358($peer,'Alice-Bob'),11,'case changes cannot bypass the same-target cooldown');
    is($peer->selectrow_array('SELECT COUNT(*) FROM KARMA_LOG'),1,'cooldown does not duplicate history');
    $bot->{_karma_cooldown}{'#test'}{'voter:alice-bob'}=time()-31;
    invoke_1358('Mediabot::Karma',$bot,'Voter','--','Alice-Bob');
    is(score_1358($peer,'Alice-Bob'),10,'expired cooldown allows the next genuine compound vote');
    is(score_1358($peer,'Bob'),10,'cooldown recovery never redirects to a suffix');
}
{
    my ($bot,$peer)=setup_1358();
    invoke_1358('Mediabot::Karma',$bot,'Voter','++','Alice-Bob',
        'Thanks Alice-Bob++! PlainNick--, Carol++ Dave--');
    is_deeply($peer->selectall_arrayref('SELECT nick,delta FROM KARMA_LOG ORDER BY rowid'),
        [['alice-bob',1],['plainnick',-1],['carol',1]],'punctuation and three-vote cap retained');
    is(score_1358($peer,'Dave'),10,'fourth token stays outside the per-message cap');
}
{
    my ($bot,$peer)=setup_1358();
    invoke_1358('Mediabot::Karma',$bot,"Voter$_",'++','Alice-Bob') for 1..5;
    invoke_1358('Mediabot::Karma',$bot,'Voter6','++','Alice-Bob','Alice-Bob++ PlainNick--');
    is(score_1358($peer,'Alice-Bob'),15,'sixth distinct voter still triggers brigade protection');
    is(score_1358($peer,'PlainNick'),9,'brigade refusal does not suppress a later valid target');
    is(score_1358($peer,'Bob'),10,'brigade tracking does not substitute the suffix');
    is($bot->{metrics}{counts}{mediabot_karma_brigade_blocks},1,'compound target brigade is counted once');
}
{
    my ($bot,$peer)=setup_1358();
    $bot->{channels}{'#zother'}=bless {id=>2}, 'MB982::Channel';
    $bot->{irc}=bless {}, 'MB982::IRC';
    my @errors = (
        invoke_1358('registry',$bot,'First','+','Alice-Bob',undef,'#TeSt'),
        invoke_1358('Mediabot::Karma',$bot,'Second','++','Alice-Bob',undef,'#TEST'),
        invoke_1358('Mediabot::Karma',$bot,'Outside','--','Alice-Bob',undef,'#ZOther'),
    );
    is_deeply([\@errors, [sort keys %{$bot->{_karma_log}}],
               $peer->selectall_arrayref('SELECT id_channel, score FROM KARMA WHERE nick=? ORDER BY id_channel',
                   undef, 'alice-bob')],
        [['','',''], ['#test','#zother'], [[1,12],[2,89]]],
        'mixed spelling shares one memory ring and the same SQL channel; the other channel is isolated');

    # Test the memory fallback rather than a successful durable history read.
    $peer->do('DROP TABLE KARMA_LOG');
    local *Mediabot::UserCommands::logBot = sub { 1 };
    my $render = sub {
        my ($cmd,@args)=@_;
        @wire=();
        my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Reader',channel=>'#tEsT',
            command=>$cmd,args=>\@args);
        $ctx->{_user_fetched}=1;
        $bot->command_registry->handler_for($cmd,'public')->($ctx);
        return [@wire];
    };
    my @views = (
        ['karma', ['log','alice-bob'], qr/by Second.*by First/s],
        ['karmahist', ['alice-bob'], qr/\(\+2\/-0\) \[memory\]/],
        ['karmgraph', ['alice-bob'], qr/net: \+2/],
        ['karmadiff', ['alice-bob'], qr/\+2 in last 24h \(2 vote\(s\), score: \+12\)/],
        ['karmainfo', ['alice-bob'], qr/received \+2/],
        ['karmatop', ['1'], qr/alice-bob\s+\+12 \(\x{2191}2 today\)/],
    );
    my @bad;
    for my $view (@views) {
        my ($cmd,$args,$pattern)=@$view;
        my $lines=$render->($cmd,@$args);
        my $text=join("\n",map {$_->[2]} @$lines);
        push @bad,$cmd unless @$lines && $text =~ $pattern && $text !~ /Outside/
            && !grep { $_->[0] ne 'public' || $_->[1] ne '#tEsT' } @$lines;
    }
    is_deeply(\@bad, [], 'IRC history views agree and retain the requested spelling on the wire');

    my $stream=bless {text=>''}, 'MB982::Stream';
    Mediabot::Partyline::Commands::_cmd_karmahist({bot=>$bot},$stream,1,'alice-bob');
    ok($stream->{text} =~ /by Second.*by First/s && $stream->{text} !~ /Outside/,
        'Partyline reads the same two events in reverse order');
}

{
    # Compile the production ingress handler without starting the daemon.
    package MB1126::Ingress;
    our ($mediabot,$bNickTriggerCommand,$BOTNICK_WASNOT_TRIGGERED,$MAIN_PROG_DAEMON,$sFullParams);
    sub _irc_target_is_channel { Mediabot::IRC::Target::is_channel(@_) }
    sub _private_message_is_sensitive {0}
    sub _private_payload_log_summary {'[fixture]'}
    sub log_debug_args {}
    sub _spark_observe_public_line {}
    Mediabot::DCC->import(qw(parse_ctcp_payload is_ctcp_chat is_dcc_chat));
    my $source=do {open my $fh,'<:encoding(UTF-8)','mediabot.pl' or die $!;local $/;<$fh>};
    for my $name (qw(_on_message_PRIVMSG_body on_message_JOIN on_message_QUIT)) {
        my ($handler)=$source =~ /^(sub \Q$name\E \{.*?^\})/ms;
        die "$name handler not found" unless defined $handler;
        eval "$handler\n1" or die $@;
    }
}

{
    my ($bot,$peer)=setup_1358();
    bless $bot,'MB1126::Bot';
    $bot->{conf}=bless {},'MB1126::Conf';
    $bot->{conversation_exclusion}=bless {},'MB1126::Exclusion';
    $bot->{hChannelsNicks}={'#test'=>['Bob','Carol','Te[u]K','Notepad[away]','Voter'],
        '#other'=>['Notepad','Dave'], '#unregistered'=>['Bob']};
    $bot->{hChannelsNicksTmp}={'#test'=>['Bob','Carol'], '#sync'=>['Gone','Here']};
    $peer->do('CREATE TABLE CHANNEL (id_channel INTEGER, name TEXT)');
    my $irc=bless {},'MB1126::IRC';
    local $MB1126::Ingress::mediabot=$bot;
    local *Mediabot::Helpers::chanset_enabled=sub {0};
    local *Mediabot::UserCommands::deliverReminders=sub {};
    local *Mediabot::UserCommands::checkTriviaAnswer=sub {};
    local *Mediabot::UserCommands::checkQuotegameAnswer=sub {};
    local *Mediabot::Update::update_completion_on_join=sub {};
    local *MB982::Metrics::set=sub {};
    @wire=();
    @warnings=();
    my $say=sub {
        my ($nick,$target,$text)=@_;
        MB1126::Ingress::_on_message_PRIVMSG_body($irc,undef,
            {prefix_nick=>$nick,targets=>$target,text=>$text});
    };
    $say->('Voter','#TeSt','bOB++');
    $say->('Other','#TeSt','merci CAROL--, Te[u]K++ !');
    is_deeply($peer->selectall_arrayref('SELECT nick,delta,from_nick FROM KARMA_LOG ORDER BY rowid'),
        [['bob',1,'Voter'],['carol',-1,'Other'],['te[u]k',1,'Other']],
        'plain PRIVMSG reaches real SQL for both operators and literal nicks on the current channel');

    for my $line (
        ['Other','#test','Notepad++ Dave-- Absent-Bob++ Bob+++ Carol--extra'],
        ['Other','#test','!echo Bob++'],
        ['Other','#test','!karma + Carol Bob++'],
        ['Other','#test','https://example.invalid/Bob++'],
        ['Other','Mediabot','Bob++'],
        ['Other','#unregistered','Bob++'],
        ['Other','#test',"\x01ACTION Bob++ \x01"],
        ['Relay','#test','Bob++'],
        ['Mediabot','#test','Bob++'],
        ['Excluded','#test','Bob++'],
        ['Other','#test','ignored Bob++'],
        ['Voter','#TEST','!karma - Bob'], # same cooldown as the bare vote
        ['Voter','#TEST','VOTER++'],
    ) {$say->(@$line)}
    $bot->channelNicksRemove('#TEST','bOB');
    my @pending_after_part=@{$bot->{hChannelsNicksTmp}{'#test'}};
    MB1126::Ingress::on_message_QUIT($irc,'gONE',{text=>'a.example b.example'});
    $say->('New','#test','Bob++');
    $say->('New','#test','!karma - Carol');
    $say->('New','#test','!karma + Notepad'); # keep historical explicit aliases
    MB1126::Ingress::on_message_JOIN($irc,'Mediabot',{target_name=>'#TEST'});
    $say->('AfterJoin','#test','Carol++');
    my $before_names=$peer->selectrow_array("SELECT COUNT(*) FROM KARMA_LOG WHERE from_nick='AfterJoin'");
    my $stale=exists $bot->{hChannelsNicksTmp}{'#test'};
    $bot->sethChannelsNicksOnChan('#TeSt','Carol');
    $say->('AfterJoin','#test','Carol++');
    is_deeply([$peer->selectall_arrayref('SELECT nick,delta,from_nick FROM KARMA_LOG ORDER BY rowid'),
        \@pending_after_part,$bot->{hChannelsNicksTmp}{'#sync'},$before_names,$stale?1:0,scalar(@warnings)],
        [[['bob',1,'Voter'],['carol',-1,'Other'],['te[u]k',1,'Other'],['carol',-1,'New'],['notepad',1,'New'],
          ['carol',1,'AfterJoin']],['Carol'],['Here'],0,0,0],
        'explicit votes still work; shorthand ignores ineligible messages and stale nicklists after PART, QUIT or rejoin');
}
done_testing;
