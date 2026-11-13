use strict;
use warnings;
use utf8;
use JSON::PP ();
use Mediabot::Users::AchievementView ();
return sub {
    my ($assert) = @_;
    my $json = JSON::PP->new->canonical;
    my $same = sub {
        my ($got, $expected, $label) = @_;
        $assert->is($json->encode($got), $json->encode($expected), $label);
    };
    my (@out, @warnings);
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    no warnings qw(redefine once);
    local *Mediabot::Users::AchievementView::botPrivmsg = sub {
        push @out, [$_[1], $_[2]]; return 1;
    };
    local *Mediabot::Users::AchievementView::botNotice = sub {
        die 'Unexpected NOTICE in leaderboard';
    };
    my @ranked = qw(Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa);
    my %counts = (Alpha=>20, Beta=>20, Gamma=>19, Delta=>18, Epsilon=>17,
        Zeta=>16, Eta=>15, Theta=>14, Iota=>13, Kappa=>12, Lambda=>11);
    my $expected = '🏆 Top achievement hunters: '
        . join('  |  ', map { "$_:$counts{$_}" } @ranked);
    for my $channel ('#room', '&room', '!room', '+room', undef, '', 'BotNick') {
        for my $populated (0, 1) {
            @out = ();
            my $ach = bless {counts=>$populated ? {%counts} : {}, reads=>0}, 'MB1289Achievements';
            my $ctx = bless {bot=>{achievements=>$ach}, channel=>$channel}, 'MB1289Context';
            my $label = (defined($channel) ? $channel : 'undef') . "/$populated";
            my $error = '';
            eval { Mediabot::Users::AchievementView::mbAchievements_ctx($ctx); 1 }
                or $error = $@;
            $assert->is($error, '', "$label: command completes");
            my $dest = defined($channel) && $channel =~ /^[#&!+]/ ? $channel : 'Caller';
            $same->(\@out, [[$dest, $populated ? $expected : 'No achievements unlocked yet.']],
                "$label: one complete response reaches caller or original channel");
            $assert->is($ach->{reads}, 1, "$label: reads leaderboard once");
            $same->($ach->{counts}, $populated ? \%counts : {}, "$label: stored counts remain intact");
        }
    }
    $same->(\@warnings, [], 'private and channel leaderboards are warning-free');
};
package MB1289Achievements;
sub list_definitions { {} }
sub count_all_nicks { $_[0]{reads}++; $_[0]{counts} }
package MB1289Context;
sub bot { $_[0]{bot} }
sub nick { 'Caller' }
sub channel { $_[0]{channel} }
sub args { ['ToP'] }
