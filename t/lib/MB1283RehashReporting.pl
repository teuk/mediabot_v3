use strict;
use warnings;
return sub {
    my ($a)=@_;
    my $code='package MB1283::Partyline; use strict; use warnings;';
    for my $entry (['Mediabot/Partyline/Commands.pm','_cmd_rehash'],['Mediabot/Partyline/Transport.pm','_report_operation_error']) {
        open my $f,'<',$entry->[0] or die $!;my $src=do {local $/;<$f>};close $f;
        my $name=$entry->[1];my ($body)=$src=~/^(sub \Q$name\E \{.*?)(?=^sub \w+|\z)/ms;
        die "missing $name" unless $body;$code.=$body;
    }
    {no warnings 'redefine';eval $code;die $@ if $@;}
    for my $logging (qw(working absent throwing late_throw)) {
        for my $outcome (qw(success false exception)) {
            my $log=bless {throw=>$logging eq 'throwing',late_throw=>$logging eq 'late_throw',entries=>[]},'MB1283::Log';
            my $bot=bless {logger=>$logging eq 'absent'?undef:$log,outcome=>$outcome,calls=>0},'MB1283::Bot';
            my $pl=bless {bot=>$bot,users=>{1=>{login=>'operator',level=>1}}},'MB1283::Partyline';
            my $stream=bless {writes=>[]},'MB1283::Stream';
            my $ok=eval {$pl->_cmd_rehash($stream,1);1};
            $a->is($ok?1:0,1,"$logging/$outcome: diagnostic failure does not escape");
            $a->is($bot->{calls},1,"$logging/$outcome: authorized operation runs once");
            $a->is(join('',@{$stream->{writes}}),"Rehashing...\r\n".($outcome eq 'success'?"OK rehash completed\r\n":"ERR rehash failed\r\n"),"$logging/$outcome: exact bounded response");
            $a->is(join('',@{$stream->{writes}})=~/private|password|hunter2/?1:0,0,"$logging/$outcome: no exception disclosure");
            if ($logging eq 'working' && $outcome ne 'success') {
                $a->is(scalar @{$log->{entries}},2,"$outcome: one request and one failure diagnostic");
                $a->is($log->{entries}[-1]=~/Partyline rehash failed for operator/ ?1:0,1,"$outcome: server diagnostic retains operation context");
            }
        }
    }
    for my $level (2,undef) {
        my $bot=bless {calls=>0},'MB1283::Bot';
        my $pl=bless {bot=>$bot,users=>{1=>{login=>'operator',level=>$level}}},'MB1283::Partyline';
        my $stream=bless {writes=>[]},'MB1283::Stream';
        $pl->_cmd_rehash($stream,1);
        $a->is($bot->{calls},0,'unauthorized caller cannot rehash');
        $a->is(join('',@{$stream->{writes}}),"Access denied: .rehash requires Master or Owner level.\r\n",'authorization response unchanged');
    }
};
package MB1283::Bot;
sub rehash_runtime_state {$_[0]{calls}++;die "private /srv/bot password=hunter2\n" if $_[0]{outcome} eq 'exception';return $_[0]{outcome} eq 'success'}
package MB1283::Log;
sub log {die "logger unavailable\n" if $_[0]{throw} || ($_[0]{late_throw} && @{$_[0]{entries}});push @{$_[0]{entries}},$_[2];1}
package MB1283::Stream;
sub write {push @{$_[0]{writes}},$_[1];1}
