# Native antifloodset command contract; replaces the copied cache simulation.
use strict;
use warnings;
use Mediabot::ChannelCommands ();
use JSON::PP ();
use Scalar::Util qw(refaddr);
use Storable qw(dclone);

{
    package MB1232Context;
    sub bot { $_[0]{bot} }
    sub nick { 'Operator' }
    sub channel { $_[0]{channel} }
    sub message { '' }
    sub args { $_[0]{args} }
    sub require_level { push @{$_[0]{bot}{events}}, ['level',$_[1]]; $_[0]{allowed} }
    sub user { undef }
    package MB1232Channel;
    sub get_id { 42 }
    sub get_name { '#Mixed' }
    package MB1232DB;
    sub prepare {
        my ($s,$sql)=@_; $sql =~ s/\s+/ /g; $sql =~ s/^ | $//g;
        push @{$s->{events}}, ['prepare',$sql];
        die $s->{exception} if $s->{mode} eq 'prepare_throw';
        return if $s->{mode} eq 'prepare_false';
        return bless {db=>$s}, 'MB1232Statement';
    }
    package MB1232Statement;
    sub execute {
        my ($s,@bind)=@_; my $db=$s->{db};
        push @{$db->{events}}, ['execute',@bind];
        die $db->{exception} if $db->{mode} eq 'execute_throw';
        return 0 if $db->{mode} eq 'execute_false';
        return '0E0' if $db->{mode} eq 'zero_rows';
        return 1;
    }
    sub fetchrow_hashref {
        my $db=$_[0]{db}; push @{$db->{events}}, ['fetch'];
        die $db->{exception} if $db->{mode} eq 'fetch_throw';
        return $db->{row} if exists $db->{row};
        return if $db->{mode} eq 'missing';
        return {nbmsg_max=>5,duration=>30,timetowait=>1};
    }
    sub finish {
        my $db=$_[0]{db}; push @{$db->{events}}, ['finish'];
        die $db->{exception} if $db->{mode} eq 'finish_throw';
        return 0 if $db->{mode} eq 'finish_false';
        return 1;
    }
    package MB1232Logger;
    sub log { my ($s,@a)=@_; push @{$s->{events}}, ['log',@a] }
}
{
    package MB1367::DBI; our @ISA=('DBI');
    package MB1367::DBI::db; our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        my $sth=$db->SUPER::prepare($sql,@rest);
        $sth->{private_kind}=$sql=~/^SELECT nbmsg_max, duration, timetowait /?'read'
            :$sql=~/UPDATE CHANNEL_FLOOD/?'write':'' if $sth;
        return $sth;
    }
    package MB1367::DBI::st; our @ISA=('DBI::st');
    sub execute {
        my ($sth,@args)=@_;
        push @{$sth->{Database}{private_calls}},[$sth->{private_kind},@args] if $sth->{private_kind};
        return $sth->SUPER::execute(@args);
    }
}
$INC{'MB1367/DBI.pm'}=__FILE__;

return sub {
    my ($assert)=@_;
    require MB1244Chaninfo;
    MB1244Chaninfo::check(sub { $assert->ok($_[0], $_[1]) });
    my $json=JSON::PP->new->canonical;
    my $equal=sub { $json->encode($_[0]) eq $json->encode($_[1]) };
    for my $mode (qw(success zero_rows prepare_false execute_false)) {
        my @events;
        my $db=bless {events=>\@events,mode=>$mode},'MB1232DB';
        my $result=Mediabot::Channel::FloodRules::write($db,42,'005','030','01');
        $assert->($result->{status} eq ($mode eq 'prepare_false' ? 'prepare_error' : $mode eq 'execute_false' ? 'execute_error' : 'updated'),"writer $mode: distinct status with DBI truth");
        $assert->($equal->($events[0],['prepare','UPDATE CHANNEL_FLOOD SET nbmsg_max = ?, duration = ?, timetowait = ? WHERE id_channel = ?']),"writer $mode: exact bound UPDATE");
        $assert->(!grep({$_->[0] eq 'finish'} @events),"writer $mode: retirement remains with command");
        if ($mode ne 'prepare_false') {
            $assert->($equal->($events[1],['execute','005','030','01',42]),"writer $mode: raw values preserved");
            $assert->(ref($result->{statement}) eq 'MB1232Statement' && refaddr($result->{statement}{db})==refaddr($db),"writer $mode: original statement handed back");
        }
    }
    for my $mode (qw(success zero_rows finish_false prepare_false execute_false prepare_throw execute_throw finish_throw denied invalid disabled display missing private unregistered)) {
        my @events; my $exception=bless {},'MB1232Exception';
        my $db=bless {events=>\@events,mode=>$mode,exception=>$exception},'MB1232DB';
        my $bot={dbh=>$db,events=>\@events,logger=>bless({events=>\@events},'MB1232Logger'),
            channels=>{'#mixed'=>bless({},'MB1232Channel')},
            _af_params=>{'#Mixed'=>{ts=>10},'#MIXED'=>{ts=>11},'#other'=>{ts=>12},
                '#mixed'=>{ts=>13},'#mIxEd'=>{ts=>14},'#mixed-more'=>{ts=>15}},
            _chan_flood_conf=>{'#Mixed'=>{x=>1},'#MIXED'=>{x=>2},'#other'=>{x=>3},
                '#mixed'=>{x=>4},'#mIxEd'=>{x=>5},'#mixed-more'=>{x=>6}}};
        my $before=$json->encode([$bot->{_af_params},$bot->{_chan_flood_conf}]);
        my $ctx=bless {bot=>$bot,channel=>'#MIXED',args=>[5,30,1],allowed=>($mode ne 'denied')},'MB1232Context';
        $ctx->{args}=['bad',30,1] if $mode eq 'invalid';
        $ctx->{args}=[] if $mode eq 'display' || $mode eq 'missing';
        $ctx->{channel}=undef if $mode eq 'private';
        $bot->{channels}={} if $mode eq 'unregistered';
        # Exercise explicit target resolution for the ordinary successful command.
        $ctx->{args}=['#MIXED',5,30,1] if $mode eq 'success';
        my ($ret,$error);
        {
            no warnings 'redefine';
            # Isolate only the diagnostic scalar; never assign to DBI magic.
            my $diagnostic='fixture DB failure';
            local *DBI::errstr=\$diagnostic;
            local *Mediabot::ChannelCommands::botNotice=sub {
                my ($b,$nick,$text)=@_; push @events,['notice',$nick,$text];
            };
            local *Mediabot::ChannelCommands::getIdChansetList=sub { push @events,['chanset']; 7 };
            local *Mediabot::ChannelCommands::getIdChannelSet=sub { push @events,['enabled']; $mode eq 'disabled' ? 0 : 8 };
            eval { $ret=Mediabot::ChannelCommands::setChannelAntiFloodParams_ctx($ctx); 1 } or $error=$@;
        }
        my $success=$mode =~ /^(success|zero_rows|finish_false)$/;
        my $throws=$mode =~ /_throw$/;
        $assert->($throws ? ref($error) && refaddr($error)==refaddr($exception) : !$error,"$mode: exception identity preserved");
        $assert->($equal->($events[0],['level','Master']),"$mode: Master authorization precedes all work");
        my @ops=map {$_->[0]} grep {$_->[0] =~ /^(prepare|execute|finish|fetch)$/} @events;
        my @expected=$mode eq 'prepare_false' || $mode eq 'prepare_throw' ? ('prepare')
            : $mode eq 'execute_throw' ? ('prepare','execute')
            : $mode eq 'display' || $mode eq 'missing' ? ('prepare','execute','fetch','finish')
            : $mode =~ /^(denied|invalid|disabled|private|unregistered)$/ ? ()
            : ('prepare','execute','finish');
        $assert->($equal->(\@ops,\@expected),"$mode: exact statement operation order");
        if ($success) {
            $assert->($equal->([$bot->{_af_params},$bot->{_chan_flood_conf}],
                [{'#other'=>{ts=>12},'#mixed-more'=>{ts=>15}},{'#other'=>{x=>3},'#mixed-more'=>{x=>6}}]),
                "$mode: invalidate every letter-case spelling and preserve distinct channels");
            $assert->(defined($ret) && $ret==0,"$mode: historical successful return");
            $assert->($equal->($events[-1],['notice','Operator','Antiflood parameters set for #MIXED: 5 lines burst, full refill over 30 sec, wait 1 sec']),"$mode: exact success reply");
        } else {
            $assert->($before eq $json->encode([$bot->{_af_params},$bot->{_chan_flood_conf}]),"$mode: caches unchanged");
            $assert->(!grep({$_->[0] eq 'notice' && $_->[2] =~ /^Antiflood parameters set/} @events),"$mode: no false success reply");
        }
        if (grep {$_->[0] eq 'execute'} @events) {
            my ($exec)=grep {$_->[0] eq 'execute'} @events;
            $assert->($equal->($exec,$mode eq 'display' || $mode eq 'missing' ? ['execute','#MIXED'] : ['execute',5,30,1,42]),"$mode: exact bind order");
        }
        if ($mode eq 'execute_false') {
            $assert->($events[-2][0] eq 'log' && $events[-2][2] eq 'SQL Error (execute): fixture DB failure' && $events[-1][0] eq 'finish','execute failure: diagnostic precedes finish');
        }
        if ($mode eq 'prepare_false') {
            $assert->($events[-1][0] eq 'log' && $events[-1][2] eq 'SQL Error (prepare): fixture DB failure','prepare failure: distinct diagnostic');
        }
        if ($mode eq 'display' || $mode eq 'missing') {
            my ($notice)=grep {$_->[0] eq 'notice'} @events;
            $assert->($equal->($notice,['notice','Operator',$mode eq 'display' ? 'antifloodset for #MIXED: 5 lines burst, full refill over 30 seconds, wait 1 second if breached' : 'No antiflood settings found for #MIXED']),"$mode: unchanged display reply");
        }
    }
    # MB1233: characterize the actual display branch before extracting its JOIN.
    for my $mode (qw(display missing nulls plural zero_rows prepare_false execute_false prepare_throw execute_throw fetch_throw finish_throw finish_false notice_throw denied unregistered)) {
        my @events; my $exception=bless {},'MB1232Exception';
        my $db=bless {events=>\@events,mode=>$mode,exception=>$exception},'MB1232DB';
        $db->{row}={nbmsg_max=>undef,duration=>undef,timetowait=>undef} if $mode eq 'nulls';
        $db->{row}={nbmsg_max=>2,duration=>15,timetowait=>2} if $mode eq 'plural';
        my $bot={dbh=>$db,events=>\@events,logger=>bless({events=>\@events},'MB1232Logger'),
            channels=>{'#mixed_%'=>bless({},'MB1232Channel')},
            _af_params=>{'#Mixed'=>{ts=>10}},_chan_flood_conf=>{'#Mixed'=>{x=>1}}};
        my $before=$json->encode([$bot->{_af_params},$bot->{_chan_flood_conf}]);
        my $ctx=bless {bot=>$bot,channel=>undef,args=>['#MiXeD_%'],allowed=>($mode ne 'denied')},'MB1232Context';
        $bot->{channels}={} if $mode eq 'unregistered';
        my ($ret,$error);
        {
            no warnings 'redefine';
            my $diagnostic='display DB failure'; local *DBI::errstr=\$diagnostic;
            local *Mediabot::ChannelCommands::botNotice=sub {
                my ($b,$nick,$text)=@_; push @events,['notice',$nick,$text];
                die $exception if $mode eq 'notice_throw';
            };
            local *Mediabot::ChannelCommands::getIdChansetList=sub {die 'display unexpectedly checks chanset'};
            eval { $ret=Mediabot::ChannelCommands::setChannelAntiFloodParams_ctx($ctx); 1 } or $error=$@;
        }
        my $throws=$mode =~ /_throw$/;
        $assert->($throws ? ref($error) && refaddr($error)==refaddr($exception) : !$error,"display $mode: exact exception identity");
        $assert->($before eq $json->encode([$bot->{_af_params},$bot->{_chan_flood_conf}]),"display $mode: no cache mutation");
        my @ops=map {$_->[0]} @events;
        my @expected=('level');
        if ($mode eq 'unregistered') {push @expected,'notice'}
        elsif ($mode ne 'denied') {
            push @expected, 'log','prepare';
            if ($mode eq 'prepare_false') {push @expected,'log'}
            elsif ($mode ne 'prepare_throw') {
                push @expected,'execute';
                if ($mode eq 'execute_false') {push @expected,'log','finish'}
                elsif ($mode ne 'execute_throw') {
                    push @expected,'fetch';
                    if ($mode ne 'fetch_throw') {push @expected,'notice';push @expected,'finish' if $mode ne 'notice_throw'}
                }
            }
        }
        $assert->($equal->(\@ops,\@expected),"display $mode: complete diagnostics/delivery/finish ordering");
        if (my ($prepare)=grep {$_->[0] eq 'prepare'} @events) {
            $assert->($equal->($prepare,['prepare','SELECT CHANNEL_FLOOD.nbmsg_max, CHANNEL_FLOOD.duration, CHANNEL_FLOOD.timetowait FROM CHANNEL JOIN CHANNEL_FLOOD ON CHANNEL.id_channel = CHANNEL_FLOOD.id_channel WHERE CHANNEL.name = ?']),"display $mode: exact JOIN and equality query");
        }
        if (my ($exec)=grep {$_->[0] eq 'execute'} @events) {
            $assert->($equal->($exec,['execute','#MiXeD_%']),"display $mode: binds original channel name, not ID or SQL pattern");
        }
        if ($mode eq 'prepare_false' || $mode eq 'execute_false') {
            my @errors=grep {$_->[0] eq 'log' && $_->[1]==1} @events;
            $assert->($equal->(\@errors,[['log',1,'SQL Error: display DB failure']]),"display $mode: historical diagnostic");
        }
        if ($mode =~ /^(display|missing|nulls|plural|zero_rows|finish_false)$/) {
            my ($notice)=grep {$_->[0] eq 'notice'} @events;
            my $body=$mode eq 'missing' ? 'No antiflood settings found for #MiXeD_%'
                : $mode eq 'nulls' ? 'antifloodset for #MiXeD_%: 0 lines burst, full refill over 0 seconds, wait 0 seconds if breached'
                : $mode eq 'plural' ? 'antifloodset for #MiXeD_%: 2 lines burst, full refill over 15 seconds, wait 2 seconds if breached'
                : 'antifloodset for #MiXeD_%: 5 lines burst, full refill over 30 seconds, wait 1 second if breached';
            $assert->($equal->($notice,['notice','Operator',$body]),"display $mode: exact wire text");
            $assert->(defined($ret) && $ret==0,"display $mode: historical return");
        }
    }
    # MB1367: fill actual admission caches, update through the real command,
    # then enforce the new SQL limits without waiting for cache expiry.
    require DBI;
    require Mediabot::IRC::OutputPolicy;
    require Mediabot::IRC::OutputBudget;
    no warnings 'redefine';
    my $now=2000;
    local *Mediabot::IRC::OutputBudget::now=sub {$now};
    for my $negative (0,1) {
        for my $private (0,1) {
            my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',
                {RootClass=>'MB1367::DBI',RaiseError=>0,PrintError=>0,AutoCommit=>1});
            $db->do('CREATE TABLE CHANNEL_FLOOD(id_channel INTEGER PRIMARY KEY,nbmsg_max INTEGER,duration INTEGER,timetowait INTEGER)');
            $db->do('INSERT INTO CHANNEL_FLOOD VALUES(99,9,90,45)');
            $db->do('INSERT INTO CHANNEL_FLOOD VALUES(42,5,30,15)') unless $negative;
            $db->{private_calls}=[];
            my (@events,@notices,@console);
            my @names=('#Mixed','#MIXED','#mixed','#mIxEd');
            my $other={'#other'=>{ts=>2000,unconfigured=>1},'#mixed-more'=>{ts=>2000,unconfigured=>1}};
            my $bot={dbh=>$db,events=>\@events,logger=>bless({events=>\@events},'MB1232Logger'),
                channels=>{'#mixed'=>bless({},'MB1232Channel')},_af_params=>dclone($other),
                _chan_flood_conf=>{map {$_=>{max=>5}} (@names,'#other','#mixed-more')},
                _flood_outq=>{'#mixed'=>{items=>[['privmsg','queued line']]}}};
            my $hooks={clock=>sub {$now},config_int=>sub {$_[2]},
                reply=>sub {push @console,'reply'},console=>sub {push @console,'console'}};
            my $check=sub {Mediabot::IRC::OutputPolicy::checkAntiFlood($bot,$_[0],1,$hooks)};
            my @warm=map {$check->($_)} @names;
            $db->do('INSERT INTO CHANNEL_FLOOD VALUES(42,5,30,15)') if $negative;
            my $state=dclone([$bot->{_af},$bot->{_global_af},$bot->{_flood_outq}]);
            my $ctx=bless {bot=>$bot,channel=>$private?undef:'#MiXeD',
                args=>$private?['#MiXeD',1,30,15]:[1,30,15],allowed=>1},'MB1232Context';
            my ($ret,$error);
            {
                local *Mediabot::ChannelCommands::botNotice=sub {push @notices,[@_[1,2]];1};
                local *Mediabot::ChannelCommands::getIdChansetList=sub {7};
                local *Mediabot::ChannelCommands::getIdChannelSet=sub {8};
                eval {$ret=Mediabot::ChannelCommands::setChannelAntiFloodParams_ctx($ctx);1} or $error=$@;
            }
            my $invalidated=dclone([$bot->{_af_params},$bot->{_chan_flood_conf}]);
            my $untouched=dclone([$bot->{_af},$bot->{_global_af},$bot->{_flood_outq}]);
            my @admission=map {[$check->($_),$check->($_)]} @names;
            my $actual=[\@warm,$error//$ret,\@notices,$invalidated,$untouched,\@admission,
                $db->{private_calls},scalar @{$bot->{_global_af}{hits}},scalar @console,
                $db->selectall_arrayref('SELECT * FROM CHANNEL_FLOOD ORDER BY id_channel')];
            my $expected=[[(0)x4],0,[['Operator','Antiflood parameters set for #MiXeD: 1 lines burst, full refill over 30 sec, wait 15 sec']],
                [$other,{'#other'=>{max=>5},'#mixed-more'=>{max=>5}}],$state,[(map {[0,1]} 1..4)],
                [(map {['read',42]} 1..4),['write',1,30,15,42],(map {['read',42]} 1..4)],8,4,
                [[42,1,30,15],[99,9,90,45]]];
            $assert->is($json->encode($actual),$json->encode($expected),
                "native SQL negative=$negative private=$private: every cached spelling adopts new limits immediately, without resetting budgets or queues");
            $db->disconnect;
        }
    }
};
