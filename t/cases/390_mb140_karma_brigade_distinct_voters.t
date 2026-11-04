# Native karma admission and operator recovery. No copied protection algorithm,
# sleeps, external database or extra process: SQLite translates SQL dialect only.
use strict;
use warnings;
use utf8;
use DBI;
use JSON::PP ();
use Mediabot::Karma;
use Mediabot::Partyline;
{
    package MB1093::DBI;
    our @ISA=('DBI');
    package MB1093::DBI::db;
    our @ISA=('DBI::db');
    sub prepare {
        my ($dbh,$sql,@rest)=@_;
        $sql =~ s/ON DUPLICATE KEY UPDATE score = score \+ \?/ON CONFLICT(id_channel,nick) DO UPDATE SET score = score + ?/;
        $sql =~ s/INSERT IGNORE INTO KARMA_LOG/INSERT OR IGNORE INTO KARMA_LOG/;
        $sql =~ s/NOW\(\)/CURRENT_TIMESTAMP/g;
        return $dbh->SUPER::prepare($sql,@rest);
    }
    package MB1093::DBI::st;
    our @ISA=('DBI::st');
    package MB1093::Bot;
    sub gethChannelsNicksOnChan {qw(Alice Alan Bob Carol)}
    package MB1093::Channel;
    sub get_id {$_[0]{id}}
    package MB1093::Log;
    sub log {1}
    package MB1093::Metrics;
    sub inc {$_[0]{$_[1]}++;1}
    package MB1093::Stream;
    sub write {$_[0]{text}.=$_[1];1}
    package MB1093::Ctx;
    sub bot {$_[0]{bot}}
    sub nick {$_[0]{nick}}
    sub channel {$_[0]{channel}}
    sub args {$_[0]{args}}
    sub message {undef}
}
$INC{'MB1093/DBI.pm'}=__FILE__;
sub fixture_390 {
    my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RootClass=>'MB1093::DBI',RaiseError=>1,PrintError=>0,AutoCommit=>1});
    $dbh->do('CREATE TABLE KARMA(id_channel INTEGER,nick TEXT,score INTEGER,UNIQUE(id_channel,nick))');
    $dbh->do('CREATE TABLE KARMA_LOG(id_channel INTEGER,nick TEXT,delta INTEGER,from_nick TEXT,score INTEGER,ts TEXT)');
    return bless {dbh=>$dbh,logger=>bless({},'MB1093::Log'),
        metrics=>bless({},'MB1093::Metrics'),
        channels=>{'#test'=>bless({id=>1},'MB1093::Channel'),
                   '#other'=>bless({id=>2},'MB1093::Channel'),
                   '&test'=>bless({id=>3},'MB1093::Channel')},
        _karma_watch=>{Watcher=>['bob','carol']},wire=>[]},'MB1093::Bot';
}
sub vote_390 {
    my ($bot,$voter,$channel,$text,$explicit)=@_;
    if ($explicit) {
        my ($target,$op)=$text=~/\A(.*)(\+\+|--)\z/;
        Mediabot::Karma::mbKarma_ctx(bless {bot=>$bot,nick=>$voter,channel=>$channel,
            args=>[$op,$target]},'MB1093::Ctx');
    } else {
        Mediabot::Karma::processKarma($bot,$voter,$channel,$text);
    }
}
sub operator_390 {
    my ($bot,$line)=@_;
    my $stream=bless {text=>''},'MB1093::Stream';
    my $party=bless {bot=>$bot,users=>{1=>{authenticated=>1,login=>'Owner',nick=>'Owner',level=>0}},
        streams=>{1=>$stream}},'Mediabot::Partyline';
    $party->_handle_line($stream,1,$line);
    return $stream->{text};
}
sub scores_390 {$_[0]{dbh}->selectall_arrayref('SELECT id_channel,nick,score FROM KARMA ORDER BY id_channel,nick')}
sub history_390 {scalar $_[0]{dbh}->selectrow_array('SELECT COUNT(*) FROM KARMA_LOG')}
return sub {
    my ($assert)=@_;
    my $json=JSON::PP->new->canonical;
    my @warnings;
    local $SIG{__WARN__}=sub {push @warnings,@_};
    no warnings qw(redefine once);
    local *Mediabot::Helpers::botPrivmsg=sub {push @{$_[0]{wire}},['public',$_[1],$_[2]];1};
    local *Mediabot::Helpers::botNotice=sub {push @{$_[0]{wire}},['notice',$_[1],$_[2]];1};
    local *Mediabot::UserCommands::botPrivmsg=sub {goto &Mediabot::Helpers::botPrivmsg};
    local *Mediabot::UserCommands::botNotice=sub {goto &Mediabot::Helpers::botNotice};

    my $bot=fixture_390();
    vote_390($bot,'Alice','#TeSt','bob++');
    vote_390($bot,'ALICE','#test','bob++',1);
    vote_390($bot,'aLiCe','#TEST','bob--');
    $assert->is($json->encode([scores_390($bot),history_390($bot),
        $bot->{metrics}{mediabot_karma_votes_total},
        scalar(grep {$_->[2]=~/wait \d+s/} @{$bot->{wire}})]),
        $json->encode([[[1,'bob',1]],1,1,2]),
        'automatic and explicit votes share one cooldown across channel and voter casing');
    vote_390($bot,'Alice','#other','bob++');
    $bot->{_karma_cooldown}{'#test'}{'alice:bob'}=time()-31;
    vote_390($bot,'Alice','#tEsT','bob--');
    $assert->is($json->encode([scores_390($bot),history_390($bot)]),
        $json->encode([[[1,'bob',0],[2,'bob',1]],3]),
        'another channel stays independent and an expired canonical cooldown admits the next vote');
    $bot->{dbh}->disconnect;

    $bot=fixture_390();
    my @spellings=qw(#test #TEST #TeSt #tEsT #Test #tesT #tEST);
    vote_390($bot,'Voter'.($_+1),$spellings[$_],'bob++') for 0..4;
    vote_390($bot,'Voter6',$spellings[5],'bob++ carol--');
    vote_390($bot,'Voter7',$spellings[6],'bob++');
    $assert->is($json->encode([scores_390($bot),history_390($bot),
        $bot->{metrics}{mediabot_karma_brigade_blocks},
        scalar(grep {$_->[2]=~/Karma brigade detected/} @{$bot->{wire}})]),
        $json->encode([[[1,'bob',5],[1,'carol',-1]],6,2,1]),
        'six distinct voters cannot split the brigade window by channel case; warn once and keep later targets usable');
    $_=time()-31 for values %{$bot->{_karma_brigade}{'brigade:bob:#test'}{nicks}};
    vote_390($bot,'Voter8','#TeST','bob--');
    $assert->is($json->encode([scores_390($bot),history_390($bot),
        $bot->{_karma_brigade}{'brigade:bob:#test'}{warned}]),
        $json->encode([[[1,'bob',4],[1,'carol',-1]],7,0]),
        'expiry removes old voters and resets the canonical brigade warning');
    $bot->{dbh}->disconnect;

    $bot=fixture_390();
    vote_390($bot,($_%2?'Alice':'ALICE'),$spellings[$_%@spellings],'bob++') for 0..7;
    $assert->ok(history_390($bot)==1 && !($bot->{metrics}{mediabot_karma_brigade_blocks}//0)
        && keys(%{$bot->{_karma_brigade}{'brigade:bob:#test'}{nicks}})==1,
        'repeated votes by one case-insensitive voter never manufacture a brigade');
    $bot->{dbh}->disconnect;

    $bot=fixture_390();
    vote_390($bot,'Alice','#test','bob++ carol++');
    vote_390($bot,'Alan','#test','bob++');
    vote_390($bot,'Alice2','#test','bob++');
    vote_390($bot,'Alice','#other','bob++');
    my $reply=operator_390($bot,'.flushcooldown ALICE #TeSt');
    vote_390($bot,'Alice','#TEST','bob++');
    $assert->ok($reply=~/Karma cooldown cleared for alice on #TeSt/
        && !exists($bot->{_karma_cooldown}{'#test'}{'alice:carol'})
        && exists($bot->{_karma_cooldown}{'#test'}{'alan:bob'})
        && exists($bot->{_karma_cooldown}{'#test'}{'alice2:bob'})
        && exists($bot->{_karma_cooldown}{'#other'}{'alice:bob'})
        && history_390($bot)==6,
        'targeted partyline recovery clears the voter’s actual pairs only and permits a genuine retry');
    my $before=$json->encode($bot->{_karma_cooldown});
    my @invalid;
    for my $args ('typo','Alice','#test extra','#test #other','Alice #test extra','Alice :bad') {
        my $text=operator_390($bot,'.flushcooldown '.$args);
        push @invalid,$args if $text!~/Usage:/ || $json->encode($bot->{_karma_cooldown}) ne $before;
    }
    $assert->is(join(',',@invalid),'',
        'malformed recovery arguments show usage and never fall through to a global flush');
    operator_390($bot,'.flushcooldown #TeSt');
    my $channel_ok=!exists($bot->{_karma_cooldown}{'#test'})
        && exists($bot->{_karma_cooldown}{'#other'}{'alice:bob'});
    vote_390($bot,'Alice','&TeSt','bob++');
    operator_390($bot,'.flushcooldown alice &TEST');
    my $local_ok=!exists($bot->{_karma_cooldown}{'&test'}{'alice:bob'});
    operator_390($bot,'.flushcooldown');
    $assert->ok($channel_ok && $local_ok && !keys(%{$bot->{_karma_cooldown}}) && !@warnings,
        'channel/global recovery retains its explicit scope, supports local channels and emits no warnings');
    $bot->{dbh}->disconnect;
};
