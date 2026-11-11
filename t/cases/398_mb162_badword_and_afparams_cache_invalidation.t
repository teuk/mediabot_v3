# Native antifloodset command contract; replaces the copied cache simulation.
use strict;
use warnings;
use Mediabot::ChannelCommands ();
use JSON::PP ();
use Scalar::Util qw(refaddr);

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

return sub {
    my ($assert)=@_;
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
            _af_params=>{'#Mixed'=>{ts=>10},'#MIXED'=>{ts=>11},'#other'=>{ts=>12}},
            _chan_flood_conf=>{'#Mixed'=>{x=>1},'#MIXED'=>{x=>2},'#other'=>{x=>3}}};
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
            $assert->($equal->([$bot->{_af_params},$bot->{_chan_flood_conf}],[{'#other'=>{ts=>12}},{'#other'=>{x=>3}}]),"$mode: invalidate both spellings and preserve unrelated channel");
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
};
