use strict;
use warnings;
use utf8;
our $NOW;
BEGIN { $NOW=1000; *CORE::GLOBAL::time=sub {$NOW} }
use Test::More;
use DBI;
use Storable qw(dclone);
use POSIX ();
use Mediabot::Mediabot;
use Mediabot::Context;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
local $ENV{TZ}='UTC';POSIX::tzset();
{
    package MB1009::Log; sub log {1}
    package MB1009::Channel; sub get_id {$_[0]{id}}
    package MB1009::Bot; our @ISA=('Mediabot');
    sub gethChannelsNicksOnChan {('Sender','Friend')}
}
my (@wire,@audit,@warnings);
local $SIG{__WARN__}=sub {push @warnings,@_};
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice=sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botPrivmsg=sub {push @wire,['public',$_[1],$_[2]];1};
local *Mediabot::UserCommands::logBot=sub {push @audit,[@_[2..4]];1};
sub setup_1384 {
    $NOW=1000;@wire=();@audit=();
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',
        {RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->do(q{CREATE TABLE REMINDERS(id_reminder INTEGER PRIMARY KEY AUTOINCREMENT,
        id_channel INTEGER,from_nick TEXT,to_nick TEXT,message TEXT,
        created_at TEXT DEFAULT 'stored',delivered INTEGER DEFAULT 0)});
    $db->do(q{INSERT INTO REMINDERS(id_channel,from_nick,to_nick,message) VALUES(8,'other','friend','Other channel')});
    my $bot=Mediabot->new({dbh=>$db});bless $bot,'MB1009::Bot';
    $bot->{logger}=bless {},'MB1009::Log';
    $bot->{channels}={map {$_->[0]=>bless({id=>$_->[1]},'MB1009::Channel')} ['#test',7],['#other',8]};
    return ($bot,$db);
}
sub invoke_1384 {
    my ($bot,$command,$args)=@_;
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Sender',channel=>'#test',command=>$command,args=>[@$args]);
    my $ok=eval {$bot->command_registry->handler_for($command,'public')->($ctx);1};
    return ($ok?'':"$@",$ctx->args);
}
sub rows_1384 {$_[0]->selectall_arrayref('SELECT id_channel,from_nick,to_nick,message,delivered FROM REMINDERS ORDER BY id_reminder')}
sub expected_1384 {
    my ($message,$notice,$args)=@_;
    return ['', $args, [[8,'other','friend','Other channel',0],[7,'sender','friend',$message,0]],
        [['notice','Sender',$notice]],[['#test','remind',"Friend: $message"]]];
}
for my $case (
    [['in','2h'],8200,'2h 0m'],
    [['dans','1h30m'],6400,'1h 30m'],
    [['at','01:00'],3600,'43m 20s'],
) {
    my ($prefix,$due,$human)=@$case;my (@actual,@expected);
    for my $command (qw(remind tell)) {
        my ($bot,$db)=setup_1384();my $args=['!','Friend',@$prefix,'Un café'];
        my ($error,$remaining)=invoke_1384($bot,$command,$args);
        push @actual,[$error,$remaining,rows_1384($db),dclone(\@wire),dclone(\@audit)];
        push @expected,expected_1384("[!] [at:$due] Un café","Reminder set for Friend (due in $human).",$args);
    }
    is_deeply(\@actual,\@expected,'urgent '.join(' ',@$prefix).': both native command names retain the requested deadline, urgency, Unicode body and scoped audit');
}
{
    my (@actual,@expected);
    for my $case ([['in','30m'],2800,'30m 0s'],[['in','2d'],173800,'2d 0h'],
                  [['in','1w'],605800,'7d 0h'],[['tomorrow'],87400,'1d 0h']) {
        my ($prefix,$due,$human)=@$case;my ($bot,$db)=setup_1384();
        my $args=['!','Friend',@$prefix,'Un café'];my ($error,$remaining)=invoke_1384($bot,'remind',$args);
        push @actual,[$error,$remaining,rows_1384($db),dclone(\@wire),dclone(\@audit)];
        push @expected,expected_1384("[!] [at:$due] Un café","Reminder set for Friend (due in $human).",$args);
    }
    is_deeply(\@actual,\@expected,'urgent minutes, days, weeks and tomorrow keep the existing relative-duration semantics');
}
{
    my (@actual,@expected);
    for my $command (qw(remind tell)) {
        my ($bot,$db)=setup_1384();invoke_1384($bot,$command,['!','Friend','in','2h','Un café']);
        @wire=();$NOW=1000;Mediabot::CommunityState::deliverReminders($bot,'Friend','#test');
        my $initial=[rows_1384($db),dclone(\@wire)];
        @wire=();$NOW=8199;Mediabot::UserCommands::deliverReminders($bot,'Friend','#test');
        my $early=[rows_1384($db),dclone(\@wire)];
        @wire=();$NOW=8200;Mediabot::CommunityState::deliverReminders($bot,'Friend','#test');
        Mediabot::UserCommands::deliverReminders($bot,'Friend','#test');
        push @actual,[$initial,$early,rows_1384($db),dclone(\@wire)];
        my $pending=[[8,'other','friend','Other channel',0],[7,'sender','friend','[!] [at:8200] Un café',0]];
        push @expected,[[$pending,[]],[$pending,[]],
            [[8,'other','friend','Other channel',0],[7,'sender','friend','[!] [at:8200] Un café',1]],
            [['public','#test','Friend: reminder from sender (stored): [!] Un café']]];
    }
    is_deeply(\@actual,\@expected,'a real urgent reminder is never claimed early, is delivered exactly once at its deadline and leaves the other channel untouched');
}
{
    my (@actual,@expected);
    for my $delay ('0h',('9'x300).'h') {
        my ($bot,$db)=setup_1384();my $args=['!','Friend','in',$delay,'Un café'];
        my ($error,$remaining)=invoke_1384($bot,'remind',$args);
        push @actual,[$error,$remaining,rows_1384($db),dclone(\@wire),dclone(\@audit)];
        push @expected,['',$args,[[8,'other','friend','Other channel',0]],
            [['notice','Sender','Invalid delay. Use a positive, representable delay.']],[]];
    }
    is_deeply(\@actual,\@expected,'zero and overflowing urgent delays are rejected before INSERT instead of creating immediate reminders');
}
{
    my (@actual,@expected);
    for my $case (
        [['Friend','in','2h','Un café'],'[at:8200] Un café','Reminder set for Friend (due in 2h 0m).'],
        [['!','Friend','Un café'],'[!] Un café','Reminder set for Friend.'],
        [['!','Friend','literal','in','2h','Un café'],'[!] literal in 2h Un café','Reminder set for Friend.'],
    ) {
        my ($args,$message,$notice)=@$case;my ($bot,$db)=setup_1384();
        my ($error,$remaining)=invoke_1384($bot,'remind',$args);
        push @actual,[$error,$remaining,rows_1384($db),dclone(\@wire),dclone(\@audit)];
        push @expected,expected_1384($message,$notice,$args);
    }
    is_deeply(\@actual,\@expected,'ordinary scheduled reminders, plain urgent messages and non-leading scheduling words remain unchanged');
}
{
    my (@actual,@expected);
    for my $case (
        [['!','daily','01:00','Friend','in','2h','Un café'],
         '[daily:01:00] [at:3600] [!] in 2h Un café','Reminder set for Friend (first delivery in 43m 20s).'],
        [['!','weekly','mon','01:00','Friend','in','2h','Un café'],
         '[weekly:1:01:00] [at:349200] [!] in 2h Un café','Reminder set for Friend (first delivery in 4d 0h).'],
    ) {
        my ($args,$message,$notice)=@$case;my ($bot,$db)=setup_1384();
        my ($error,$remaining)=invoke_1384($bot,'remind',$args);
        push @actual,[$error,$remaining,rows_1384($db),dclone(\@wire),dclone(\@audit)];
        push @expected,expected_1384($message,$notice,$args);
    }
    is_deeply(\@actual,\@expected,'daily and weekly urgency metadata keep their calendar schedule and literal message body');
}
{
    my (@actual,@expected);
    for my $size (498,499) {
        my ($bot,$db)=setup_1384();my $body='é'x$size;
        my $args=['!','Friend','in','2h',$body];my ($error,$remaining)=invoke_1384($bot,'remind',$args);
        push @actual,[$error,$remaining,rows_1384($db),dclone(\@wire),dclone(\@audit)];
        push @expected,$size==498
            ?expected_1384('[!] [at:8200] '.$body,'Reminder set for Friend (due in 2h 0m).',$args)
            :['',$args,[[8,'other','friend','Other channel',0]],
              [['notice','Sender','Message too long (max 512 chars).']],[]];
    }
    is_deeply(\@actual,\@expected,'urgency and scheduling metadata share the 512-character budget, including its exact Unicode boundary');
}
is_deeply(\@warnings,[],'urgent scheduling emits no warnings');
done_testing;
