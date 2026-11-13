use strict;
use warnings;
use Test::More;
use Mediabot::Users::Horoscope ();
return sub {
    my (@out,@gates,@progress,@warnings);my ($allowed,$rendered)=(0,0);
    local $SIG{__WARN__}=sub {push @warnings,@_};
    no warnings qw(redefine once);
    local *Mediabot::Users::Horoscope::botNotice=sub {push @out,['notice',$_[1],$_[2]];1};
    local *Mediabot::Users::Horoscope::botPrivmsg=sub {push @out,['message',$_[1],$_[2]];1};
    local *Mediabot::Users::Horoscope::_ach_progress=sub {push @progress,[@_[1..3]];9};
    local *Mediabot::Helpers::chanset_enabled=sub {push @gates,[@_[1..$#_]];$allowed};
    local *Mediabot::Helpers::channel_lang=sub {'en'};
    local *Mediabot::External::Horoscope::normalize_sign=sub {undef};
    local *Mediabot::External::Horoscope::clean_text=sub {undef};
    local *Mediabot::External::Horoscope::compact_lines=sub {$rendered++;['first line','second line']};
    for my $channel ('#room','&room','!room','+room',undef,'','Caller') {
        for my $enabled (0,1) {
            @out=();@gates=();@progress=();$rendered=0;$allowed=$enabled;
            my $db=bless {queries=>0},'MB1288DB';
            my $ach=bless {calls=>[]},'MB1288Achievements';
            my $bot={dbh=>$db,achievements=>$ach};
            my $ctx=bless {bot=>$bot,channel=>$channel},'MB1288Context';
            my $public=defined($channel) && $channel =~ /^[#&!+]/;
            my $label=(defined($channel)?$channel:'undef')."/$enabled";
            my $error='';eval {Mediabot::Users::Horoscope::mbHoroscope_ctx($ctx);1} or $error=$@;
            is($error,'',"$label: command completes without throwing");
            is_deeply(\@gates,$public?[[$channel,'Games',default=>1]]:[],
                "$label: only channel contexts consult Games");
            if ($public && !$enabled) {
                is_deeply(\@out,[['notice','Caller',"Games are disabled on $channel (chanset -Games)"]],
                    "$label: disabled channel receives only the refusal notice");
                is_deeply([$db->{queries},$rendered,\@progress,$ach->{calls},$bot->{_horoscope_count}{Caller}//0],
                    [0,0,[],[],0],"$label: refusal precedes SQL, rendering and achievement work");
            } else {
                my $dest=$public?$channel:'Caller';
                is_deeply(\@out,[['message',$dest,'first line'],['message',$dest,'second line']],
                    "$label: both output lines retain their proper destination");
                is_deeply([$db->{queries},$rendered,$bot->{_horoscope_count}{Caller}],[1,1,1],
                    "$label: accepted command executes once");
                is_deeply(\@progress,$public?[['horoscope','Caller',$channel]]:[],
                    "$label: persistent progress remains channel-scoped");
                is_deeply($ach->{calls},$public?[['Caller',$channel,9]]:[],
                    "$label: achievement check uses the same channel scope");
            }
        }
    }
    is_deeply(\@warnings,[],'private undefined channel and all channel types remain warning-free');
};
package MB1288DB;
sub prepare {$_[0]{queries}++;bless {},'MB1288Statement'}
package MB1288Statement;
sub execute {1} sub fetchrow_hashref {undef} sub finish {1}
package MB1288Achievements;
sub check_horoscope {my ($s,@args)=@_;push @{$s->{calls}},\@args;1}
package MB1288Context;
sub bot {$_[0]{bot}} sub channel {$_[0]{channel}} sub nick {'Caller'} sub args {[]}
