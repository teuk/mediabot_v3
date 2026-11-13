use strict;
use warnings;
use JSON::PP ();
use Mediabot::Users::AchievementView ();
return sub {
    my ($assert) = @_;
    my (@out, @warnings);
    my $json = JSON::PP->new->canonical;
    my $same = sub { $assert->is($json->encode($_[0]), $json->encode($_[1]), $_[2]) };
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    no warnings qw(redefine once);
    local *Mediabot::Users::AchievementView::botPrivmsg = sub { push @out, ['msg', $_[1], $_[2]]; 1 };
    local *Mediabot::Users::AchievementView::botNotice = sub { push @out, ['notice', $_[1], $_[2]]; 1 };
    for my $channel ('#room', '&room', '!room', '+room') {
        for my $mode ('empty', 'earned', 'all', 'progress', 'prog') {
            @out = ();
            my $ach = bless {calls=>[], earned=>$mode ne 'empty'}, 'MB1290Achievements';
            my @args = $mode =~ /^(?:empty|earned)$/ ? ('Other') : ($mode, 'Other');
            my $ctx = bless {bot=>{achievements=>$ach}, channel=>$channel, args=>\@args}, 'MB1290Context';
            my $error = '';
            eval { Mediabot::Users::AchievementView::mbAchievements_ctx($ctx); 1 } or $error=$@;
            $assert->is($error, '', "$channel/$mode: completes");
            my $progress = $mode =~ /^prog/;
            my $calls = $progress ? [['snapshot', 'other', $channel]]
                : $mode eq 'all' ? [['all', 'other']]
                : [['get', 'other', $channel], ['goals', 'other', $channel, 3]];
            $same->($ach->{calls}, $calls, "$channel/$mode: correct storage scope and goal lookup");
            $same->([map { [@$_[0,1]] } @out],
                [map { [$progress ? 'notice' : 'msg', $progress ? 'Caller' : $channel] }
                    1..($progress ? 2 : $mode eq 'empty' || $mode eq 'all' ? 2 : 4)],
                "$channel/$mode: output type, destination and count");
            my $text = join "\n", map { $_->[2] } @out;
            $assert->ok($text !~ /SECRET/, "$channel/$mode: locked secret stays hidden");
            $assert->like($text, $progress ? qr/1\/2 visible unlocked, 1 in progress/ :
                $mode eq 'all' ? qr/\(all channels\)/ :
                $mode eq 'empty' ? qr/Closest: .*Goal/ : qr/Next: .*Goal/,
                "$channel/$mode: correct progress presentation");
        }
    }
    for my $channel (undef, '', 'BotNick') {
        @out = ();
        my $ach=bless {calls=>[], earned=>1}, 'MB1290Achievements';
        my $ctx=bless {bot=>{achievements=>$ach},channel=>$channel,args=>['progress']}, 'MB1290Context';
        Mediabot::Users::AchievementView::mbAchievements_ctx($ctx);
        $same->(\@out, [['notice','Caller','Syntax: !achievements progress [nick]  (in a channel)']],
            'private progress still requires an explicit channel context');
        $same->($ach->{calls}, [], 'private progress does not query a channel');
        @out=(); $ctx->{args}=['all'];
        Mediabot::Users::AchievementView::mbAchievements_ctx($ctx);
        $same->([map { [@$_[0,1]] } @out], [['msg','Caller'],['msg','Caller']],
            'private cross-channel view stays private');
        $same->($ach->{calls}, [['all','caller']], 'cross-channel view never requests channel goals');
    }
    $same->(\@warnings, [], 'channel and private views remain warning-free');
};
package MB1290Context;
sub bot { $_[0]{bot} } sub channel { $_[0]{channel} } sub nick { 'Caller' } sub args { $_[0]{args} }
package MB1290Achievements;
sub list_definitions { {
    earned=>{name=>'Earned',emoji=>'*',rarity=>'common'},
    goal=>{name=>'Goal',emoji=>'*',rarity=>'common'},
    secret=>{name=>'SECRET',emoji=>'*',rarity=>'rare',hidden=>1},
} }
sub rarity_color { '' }
sub get_for_nick { my ($s,@a)=@_; push @{$s->{calls}}, ['get',@a]; $s->{earned}?{earned=>1}:{} }
sub get_for_nick_all { my ($s,@a)=@_; push @{$s->{calls}}, ['all',@a]; {earned=>1} }
sub next_goals { my ($s,@a)=@_; push @{$s->{calls}}, ['goals',@a]; [{id=>'goal',current=>1,threshold=>2,pct=>50}] }
sub progress_snapshot {
    my ($s,@a)=@_; push @{$s->{calls}}, ['snapshot',@a];
    return {earned=>{unlocked=>1}, goal=>{unlocked=>0,measurable=>1,current=>1,threshold=>2,pct=>50},
        secret=>{hidden=>1,unlocked=>0,measurable=>1,current=>9,threshold=>10,pct=>90}};
}
