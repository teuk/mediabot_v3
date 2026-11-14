package MB881OutputFixture;
use strict;
use warnings;
use utf8;
use Mediabot::Helpers ();

# Only integration seams and IO are replaced. Sender, TextBudget, classification,
# redaction and the deferred queue remain their production implementations.
sub new_bot {
    return bless {
        policy => {}, blocked => 0, events => [],
        logger => bless({rows => []}, 'MB881::Logger'),
        irc => bless({wire => []}, 'MB881::IRC'),
        metrics => bless({counts => {}}, 'MB881::Metrics'),
        dbh => bless({queries => [], finishes => 0, words => []}, 'MB881::DBH'),
    }, 'MB881::Bot';
}
sub with_policy {
    my ($code) = @_;
    no warnings 'redefine';
    local *Mediabot::Helpers::getIdChansetList = sub {$_[1]};
    local *Mediabot::Helpers::getIdChannelSet = sub {$_[0]{policy}{$_[2]} ? 1 : undef};
    local *Mediabot::Helpers::checkAntiFlood = sub {$_[0]{blocked} ? 1 : 0};
    local *Mediabot::Helpers::logBotAction = sub {push @{$_[0]{events}}, ['history', @_[1 .. 5]]; 1};
    local *Mediabot::Helpers::noticeConsoleChan = sub {push @{$_[0]{events}}, ['console', $_[1]]; 1};
    return $code->();
}
package MB881::Bot;
sub getLoop {$_[0]{loop}}
package MB881::Logger;
sub log {push @{$_[0]{rows}}, [$_[1], $_[2]]; 1}
package MB881::IRC;
sub nick_folded {'mediabot'}
sub do_PRIVMSG {my ($s, %args) = @_; push @{$s->{wire}}, {kind => 'privmsg', %args}; 1}
sub do_NOTICE {my ($s, %args) = @_; push @{$s->{wire}}, {kind => 'notice', %args}; 1}
package MB881::Metrics;
sub inc {$_[0]{counts}{$_[1]}++; 1}
package MB881::DBH;
sub prepare {
    my ($self, $sql) = @_;
    push @{$self->{queries}}, {sql => $sql};
    return undef if ($self->{failure} // '') eq 'prepare';
    return bless {dbh => $self, words => [@{$self->{words}}]}, 'MB881::STH';
}
package MB881::STH;
sub execute {
    my ($self, @bind) = @_;
    $self->{dbh}{queries}[-1]{bind} = \@bind;
    return ($self->{dbh}{failure} // '') eq 'execute' ? 0 : 1;
}
sub fetchrow_hashref {my $word = shift @{$_[0]{words}}; defined($word) ? {badword => $word} : undef}
sub err {0}
sub finish {$_[0]{dbh}{finishes}++; 1}
package MB881::Timer;
sub new {my ($class, %args) = @_; bless \%args, $class}
sub start {$_[0]{started} = 1; 1}
sub stop {$_[0]{stopped} = 1; 1}
package MB881::Loop;
sub new {bless {pending => [], delays => []}, shift}
sub add {push @{$_[0]{pending}}, $_[1]; push @{$_[0]{delays}}, $_[1]{delay}; 1}
sub remove {$_[1]{removed} = 1; 1}
sub tick {my $t = shift @{$_[0]{pending}}; $t->{on_expire}->() if $t}
sub drain {my ($s) = @_; my $n = 0; while (@{$s->{pending}}) {die 'fixture did not finish' if ++$n > 100; $s->tick}}
1;

# MB1235: fault matrix shared by native integration and offline package checks.
package MB1235::DB;
sub prepare {
    my ($s,$sql)=@_; push @{$s->{calls}},['prepare',$sql];
    die "prepare fault\n" if $s->{mode} eq 'prepare_throw';
    return if $s->{mode} eq 'prepare_false';
    return bless {db=>$s,rows=>[@{$s->{rows}}]},'MB1235::STH';
}
package MB1235::STH;
sub execute {
    my ($s,@bind)=@_;push @{$s->{db}{calls}},['execute',@bind];
    die "execute fault\n" if $s->{db}{mode} eq 'execute_throw';
    return 0 if $s->{db}{mode} eq 'execute_false';
    return '0E0';
}
sub fetchrow_hashref {
    my ($s)=@_;push @{$s->{db}{calls}},['fetch'];
    die "fetch fault\n" if $s->{db}{mode} eq 'fetch_throw' && !@{$s->{rows}};
    return shift @{$s->{rows}};
}
sub err {
    my ($s)=@_;push @{$s->{db}{calls}},['err'];
    die "err fault\n" if $s->{db}{mode} eq 'err_throw';
    return $s->{db}{mode} eq 'partial_error' ? 1 : 0;
}
sub finish {
    my ($s)=@_;push @{$s->{db}{calls}},['finish'];
    die "finish fault\n" if $s->{db}{mode} eq 'finish_throw';
    return $s->{db}{mode} eq 'finish_false' ? 0 : 1;
}
package MB881OutputFixture;
sub check_badword_read_contracts {
    require Test::More;
    require Mediabot::IRC::Sender;
    for my $mode (qw(success empty prepare_false prepare_throw execute_false execute_throw fetch_throw partial_error bad_row bad_value err_throw finish_throw finish_false)) {
        my $bot=new_bot();
        my $rows=$mode eq 'empty' ? [] : $mode eq 'bad_row' ? [{badword=>'partial'},[]]
            : $mode eq 'bad_value' ? [{badword=>'partial'},{badword=>[]}]
            : [{badword=>'BLoCKED'},{badword=>undef},{badword=>'BLoCKED'},{badword=>'0'}];
        my $db=bless {mode=>$mode,rows=>$rows,calls=>[]},'MB1235::DB';
        $bot->{dbh}=$db;
        my $old={ts=>1,words=>['confirmed']};
        $bot->{_badword_cache}={'#mixed_%'=>$old,'#other'=>{ts=>2,words=>['other']}};
        my $good=$mode =~ /^(success|empty|finish_throw|finish_false)$/;
        my ($result,$error);
        eval {$result=Mediabot::IRC::Sender::_badwords_for_channel($bot,'#MiXeD_%');1} or $error=$@;
        Test::More::ok(!$error,"$mode: reader/policy failure remains contained");
        my $expected=$good ? ($mode eq 'empty' ? [] : ['blocked','blocked','0']) : ['confirmed'];
        Test::More::is_deeply($result,$expected,"$mode: complete normalized list or confirmed fallback, never partial");
        Test::More::is_deeply($bot->{_badword_cache}{'#other'},{ts=>2,words=>['other']},"$mode: unrelated channel intact");
        Test::More::is($bot->{_badword_cache}{'#mixed_%'}{ts}==1 ? 1:0,$good?0:1,"$mode: only successful reads advance age");
        my @ops=map {$_->[0]} @{$db->{calls}};
        Test::More::is(scalar(grep {$_ eq 'finish'} @ops),$mode =~ /^prepare_/ ? 0:1,"$mode: acquired statement finished once");
        Test::More::is($bot->{metrics}{counts}{mediabot_db_query_errors_total}//0,$good?0:1,"$mode: exact error accounting");
        Test::More::is(scalar @{$bot->{logger}{rows}},$good?0:1,"$mode: one bounded diagnostic on failure");
        Test::More::is_deeply($db->{calls}[0],['prepare','SELECT badword FROM CHANNEL JOIN BADWORDS ON BADWORDS.id_channel = CHANNEL.id_channel WHERE CHANNEL.name = ?'],"$mode: exact query");
        if ($mode !~ /^prepare_/) {
            Test::More::is_deeply($db->{calls}[1],['execute','#MiXeD_%'],"$mode: original name bound literally");
        }
        my $count=scalar @{$db->{calls}};
        Mediabot::IRC::Sender::_badwords_for_channel($bot,'#mIXED_%');
        Test::More::is(scalar(@{$db->{calls}})>$count?1:0,$good?0:1,"$mode: failures retry, successes share case-insensitive cache");
        if (!$good) {
            delete $bot->{_badword_cache}{'#mixed_%'};
            Test::More::is_deeply(Mediabot::IRC::Sender::_badwords_for_channel($bot,'#MiXeD_%'),[],"$mode: first failure keeps historical empty fallback");
            Test::More::ok(!exists $bot->{_badword_cache}{'#mixed_%'},"$mode: failed initial read is not cached");
        }
    }
}
1;

package MB1236::Context;
sub bot {$_[0]{bot}}
sub nick {'operator'}
sub args {['#TeST','  Mixed','word  ']}
sub channel {'#test'}
sub user {$_[0]{user}}
sub message {undef}
package MB1236::User;
sub is_authenticated {$_[0]{mode} ne 'unauthenticated'}
sub has_level {$_[0]{mode} ne 'denied'}
sub nickname {'operator'}
sub level_description {'fixture'}
package MB1236::Channel;
sub get_id {42}
sub get_name {'#Test'}
package MB1236::DB;
sub prepare {
    my ($s,$sql)=@_;my $stage=$sql =~ /^SELECT/ ? 'select' : 'write';
    push @{$s->{events}},['prepare',$stage,$sql];
    die $s->{exception} if $s->{mode} eq $stage.'_prepare_throw';
    return if $s->{mode} eq $stage.'_prepare_false';
    return bless {db=>$s,stage=>$stage},'MB1236::STH';
}
package MB1236::STH;
sub execute {
    my ($s,@bind)=@_;my $d=$s->{db};push @{$d->{events}},['execute',$s->{stage},@bind];
    die $d->{exception} if $d->{mode} eq $s->{stage}.'_execute_throw';
    return 0 if $d->{mode} eq $s->{stage}.'_execute_false';
    return '0E0';
}
sub fetchrow_hashref {
    my ($s)=@_;my $d=$s->{db};push @{$d->{events}},['fetch','select'];
    die $d->{exception} if $d->{mode} eq 'select_fetch_throw';
    my $exists=($d->{op} eq 'add' ? $d->{mode} eq 'noop' : $d->{mode} ne 'noop');
    return $exists ? {id_badwords=>7,badword=>'Mixed word'} : undef;
}
sub finish {
    my ($s)=@_;my $d=$s->{db};push @{$d->{events}},['finish',$s->{stage}];
    die $d->{exception} if $d->{mode} eq $s->{stage}.'_finish_throw';
    return 1;
}
package MB1236::Logger;
sub log {push @{$_[0]{events}},['diagnostic',$_[1],$_[2]]}
package MB881OutputFixture;
sub check_badword_write_contracts {
    require Test::More;require Scalar::Util;require Mediabot::ChannelCommands;
    for my $op (qw(add remove)) {
        for my $mode (qw(success noop unauthenticated denied select_prepare_false select_execute_false select_prepare_throw select_execute_throw select_fetch_throw select_finish_throw write_prepare_false write_execute_false write_prepare_throw write_execute_throw write_finish_throw notice_throw)) {
            my @events;my $exception=bless {},'MB1236::Exception';
            my $bot=new_bot();$bot->{channels}={'#test'=>bless({},'MB1236::Channel')};
            $bot->{dbh}=bless {events=>\@events,mode=>$mode,op=>$op,exception=>$exception},'MB1236::DB';
            $bot->{logger}=bless {events=>\@events},'MB1236::Logger';
            my $cache={'#test'=>{ts=>1},'#Test'=>{ts=>2},'#TeST'=>{ts=>3},'#other'=>{ts=>4}};
            $bot->{_badword_cache}={%$cache};
            my $ctx=bless {bot=>$bot,user=>bless({mode=>$mode},'MB1236::User')},'MB1236::Context';
            my ($ret,$error);
            {
                no warnings 'redefine';my $diag='write fixture fault';local *DBI::errstr=\$diag;
                local *Mediabot::ChannelCommands::botNotice=sub {push @events,['notice',$_[2]];die $exception if $mode eq 'notice_throw'};
                local *Mediabot::ChannelCommands::logBot=sub {push @events,['audit',$_[3],$_[4]]};
                local *Mediabot::ChannelCommands::noticeConsoleChan=sub {push @events,['console',$_[1]]};
                eval {$ret=$op eq 'add' ? Mediabot::ChannelCommands::channelAddBadword_ctx($ctx) : Mediabot::ChannelCommands::channelRemBadword_ctx($ctx);1} or $error=$@;
            }
            my $mutated=$mode =~ /^(success|write_finish_throw|notice_throw)$/;
            Test::More::ok($mode =~ /_throw$/ ? ref($error) && Scalar::Util::refaddr($error)==Scalar::Util::refaddr($exception) : !$error,"$op $mode: exception identity");
            Test::More::is_deeply($bot->{_badword_cache},$mutated?{'#other'=>{ts=>4}}:$cache,"$op $mode: invalidate only after accepted mutation; preserve no-ops");
            my @exec=grep {$_->[0] eq 'execute'} @events;
            for my $exec (@exec) {
                Test::More::is_deeply($exec,$exec->[1] eq 'select' ? ['execute','select',42,'Mixed word'] : $op eq 'add' ? ['execute','write',42,'Mixed word'] : ['execute','write',7],"$op $mode: exact identity and raw word binding");
            }
            if ($mode eq 'success') {
                Test::More::is($ret,1,"$op: DBI 0E0 remains success");
                Test::More::is_deeply([map {$_->[0]} @events],[qw(prepare execute fetch finish prepare execute notice audit finish)],"$op: exact operation ordering");
                Test::More::is_deeply($events[6],['notice',$op eq 'add' ? "Added badword 'Mixed word' to #TeST" : "Removed badword 'Mixed word' from #TeST"],"$op: wire reply unchanged");
            }
            if ($mode eq 'noop') {
                Test::More::is_deeply([map {$_->[0]} @events],$op eq 'add' ? [qw(prepare execute fetch notice audit finish)] : [qw(prepare execute fetch finish notice)],"$op: no-op has no write and preserves finish ordering");
            }
            if ($mode =~ /_(prepare|execute)_false$/) {
                my @diagnostics=grep {$_->[0] eq 'diagnostic'} @events;
                Test::More::is(scalar @diagnostics,1,"$op $mode: one diagnostic");
                Test::More::like($diagnostics[0][2],qr/write fixture fault/,"$op $mode: native diagnostic retained");
                Test::More::is($events[-1][0],$mode =~ /execute_false$/ ? 'finish':'diagnostic',"$op $mode: diagnostics precede acquired statement finish");
            }
            if ($mode eq 'unauthenticated' || $mode eq 'denied') {
                Test::More::is(scalar @exec,0,"$op $mode: no database operation before authorization");
            }
        }
    }
}
package MB1304::Context;
our @ISA = ('MB1236::Context');
sub args {$_[0]{args}}
sub channel {$_[0]{channel}}
package MB1304::Channel;
sub get_id {$_[0]{id}}
sub get_name {$_[0]{name}}
package MB881OutputFixture;
sub check_badword_channel_scope {
    require DBI;
    for my $prefix ('#', '&', '!', '+') {
        for my $explicit (0, 1) {
            my $target=$prefix.'Other';
            my $dbh=DBI->connect('dbi:SQLite:dbname=:memory:','','',{RaiseError=>1,PrintError=>0,sqlite_unicode=>1});
            $dbh->do('CREATE TABLE BADWORDS (id_badwords INTEGER PRIMARY KEY, id_channel INTEGER, badword TEXT)');
            $dbh->do('INSERT INTO BADWORDS (id_channel,badword) VALUES (1,?)',undef,"$target café noir");
            my $bot=new_bot();$bot->{dbh}=$dbh;
            $bot->{channels}={
                '#current'=>bless({id=>1,name=>'#current'},'MB1304::Channel'),
                lc($target)=>bless({id=>2,name=>$target},'MB1304::Channel')};
            my $ctx=bless {bot=>$bot,user=>bless({mode=>'success'},'MB1236::User'),
                channel=>$explicit?'#current':$target,
                args=>[$explicit?($target):(), 'café','noir']},'MB1304::Context';
            no warnings 'redefine';
            local *Mediabot::ChannelCommands::botNotice=sub {};
            local *Mediabot::ChannelCommands::logBot=sub {};
            local *Mediabot::ChannelCommands::noticeConsoleChan=sub {};
            for my $op ('add','remove') {
                $bot->{_badword_cache}={'#current'=>{ts=>1},lc($target)=>{ts=>2},$target=>{ts=>3}};
                my $ret=$op eq 'add' ? Mediabot::ChannelCommands::channelAddBadword_ctx($ctx) : Mediabot::ChannelCommands::channelRemBadword_ctx($ctx);
                Test::More::is($ret,1,"$op $target explicit=$explicit succeeds");
                Test::More::is_deeply($dbh->selectall_arrayref('SELECT id_channel,badword FROM BADWORDS ORDER BY id_channel'),
                    [[1,"$target café noir"],$op eq 'add'?([2,'café noir']):()],
                    "$op $target explicit=$explicit changes only the intended channel and exact Unicode phrase");
                Test::More::is_deeply($bot->{_badword_cache},{'#current'=>{ts=>1}},"$op $target invalidates only target cache");
            }
            for my $guard ('unknown', 'private', 'denied', 'unauthenticated') {
                $ctx->{user}{mode}=$guard;
                $ctx->{channel}=$guard eq 'private' ? undef : '#current';
                $ctx->{args}=$guard eq 'private' ? ['café'] : [$prefix.'Missing','café'];
                my $before=$dbh->selectall_arrayref('SELECT * FROM BADWORDS ORDER BY id_badwords');
                $bot->{_badword_cache}={'#current'=>{ts=>1}};
                Mediabot::ChannelCommands::channelAddBadword_ctx($ctx);
                Mediabot::ChannelCommands::channelRemBadword_ctx($ctx);
                Test::More::is_deeply($dbh->selectall_arrayref('SELECT * FROM BADWORDS ORDER BY id_badwords'),$before,
                    "$target $guard refuses both mutations without falling back to current channel");
                Test::More::is_deeply($bot->{_badword_cache},{'#current'=>{ts=>1}},"$target $guard preserves cache");
            }
            $dbh->disconnect;
        }
    }
}

1;
