use strict;
use warnings;
use Mediabot::Fullop;
use JSON::PP ();

{
    package MB733R2::Bans;
    sub mask_from_hostmask { '*!*actor@users.example' }
    sub add_ban {
        my ($self, %row) = @_;
        push @{ $self->{added} }, \%row;
        return (scalar(@{ $self->{added} }), undef);
    }
    package MB733R2::Logger;
    sub log { push @{ $_[0]{lines} }, $_[2] }
}

sub mb733r2_guard {
    my (%opts) = @_;
    my (@sent, @said, @logs);
    my $bans = bless { added => [], existing => ['*!*first@host.example', '*!*second@host.example'] }, 'MB733R2::Bans';
    my $clock = 1000;
    my $guard = Mediabot::Fullop->new(
        network => ($opts{network} // 'EpiKnet'),
        bot => { logger => bless({ lines => \@logs }, 'MB733R2::Logger') },
        enabled_cb => sub { exists($opts{enabled}) ? $opts{enabled} : 1 },
        privileged_cb => sub { 0 },
        channel_id_cb => sub { 42 }, channel_ban => $bans,
        send_cb => sub { push @sent, [@_]; 1 },
        announce_cb => sub { push @said, [@_]; 1 },
        now_cb => sub { $clock },
    );
    $guard->update_isupport('PREFIX=(qaohv)~&@%+', 'CHANMODES=beI,k,l,imnpst');
    return ($guard, $bans, \@sent, \@said, \@logs, \$clock);
}

return sub {
    my ($a) = @_;
    my $json = JSON::PP->new->canonical;
    my $equal = sub { $a->is($json->encode($_[0]), $json->encode($_[1]), $_[2]) };
    my $official = 'Cronos!services@olympe.epiknet.org';

    # BotServ checks its own FANTASY access. No Mediabot login, successful
    # command handler, pending delegation or shared command clock is required.
    my ($g, $bans, $sent, $said, $logs, $clock) = mb733r2_guard();
    my $existing = [@{ $bans->{existing} }];
    for my $event (
        ['+b', ['*!*@first.example'], 'independent BotServ kickban'],
        ['+b', ['*!*@second.example'], 'another legitimate BotServ kickban'],
        ['-b', ['*!*@first.example'], 'BotServ unban'],
        ['+qo', ['Founder', 'Founder'], 'BotServ founder restoration'],
        ['+b-o', ['*!*@third.example', 'Visitor'], 'combined service moderation'],
        ['+q', ['Founder'], 'later service rank grant'],
    ) {
        $$clock += 60;
        my $r = $g->handle_mode(channel => '#open', prefix => $official,
            mode_string => $event->[0], mode_args => $event->[1]);
        $a->is($r->{sanctioned}, 0, "mb733-r2: $event->[2] is not sanctioned");
        $a->is($r->{corrected}, 0, "mb733-r2: $event->[2] is not reversed");
        $a->is($r->{privileged}, 1, "mb733-r2: $event->[2] uses service authority");
        $a->is($r->{delegated}, 0, "mb733-r2: $event->[2] needs no five-second token");
    }
    $equal->([$sent, $said, $bans->{added}], [[], [], []],
        'mb733-r2: no corrective mode, public warning, kick or persistent service ban');
    $equal->($bans->{existing}, $existing, 'mb733-r2: existing permanent bans remain untouched');
    $a->ok(!$g->{channel_state}{'#open'}{list}{b}{'*!*@first.example'},
        'mb733-r2: accepted service unban is reflected in mode state');
    $a->ok($g->{channel_state}{'#open'}{list}{b}{'*!*@second.example'},
        'mb733-r2: another service ban stays present');
    $a->like(join("\n", @$logs), qr/Fullop: accepted network service Cronos!services\@olympe\.epiknet\.org on #open modes=\+b/,
        'mb733-r2: service authority decision has an application debug record');

    # Identity is the complete service prefix on the exact network profile.
    for my $case (
        ['Epiknet', $official, 0],
        ['ePiKnEt', 'cRONOS!services@OLYMPE.EPIKNET.ORG', 0],
        ['OtherNet', $official, 1],
        ['FakeEpiKnet', $official, 1],
        ['Epiknet', 'Cronos!visitor@olympe.epiknet.org', 1],
        ['Epiknet', 'Cronos!services@users.example', 1],
        ['Epiknet', 'Cronos!services@olympe.epiknet.org.example', 1],
        ['Epiknet', 'Other!services@olympe.epiknet.org', 1],
        ['Epiknet', 'OrdinaryOp!person@users.example', 1],
    ) {
        my ($guard, $store) = mb733r2_guard(network => $case->[0]);
        my $r = $guard->handle_mode(channel => '#open', prefix => $case->[1],
            mode_string => '+b', mode_args => ['*!*@blocked.example']);
        $a->is($r->{sanctioned}, $case->[2], "mb733-r2: service boundary $case->[0] / $case->[1]");
        $a->is(scalar(@{ $store->{added} }), $case->[2], 'mb733-r2: only untrusted actors receive a sanction');
    }
    my ($changed) = mb733r2_guard();
    $changed->update_isupport('NETWORK=OtherNet');
    my $r = $changed->handle_mode(channel => '#open', prefix => $official,
        mode_string => '+b', mode_args => ['*!*@blocked.example']);
    $a->is($r->{sanctioned}, 1, 'mb733-r2: live server network change revokes EpiKnet service authority');

    my ($restart, $restart_bans, $restart_sent) = mb733r2_guard();
    $r = $restart->handle_mode(channel => '#open', prefix => $official,
        mode_string => '+b', mode_args => ['*!*@late.example']);
    $equal->([$restart_sent, $restart_bans->{added}], [[], []],
        'mb733-r2: a fresh process needs no replay of the human command');

    my ($normal, $normal_bans, $normal_sent) = mb733r2_guard();
    $r = $normal->handle_mode(channel => '#open', prefix => 'Visitor!person@users.example',
        mode_string => '+b-o+m', mode_args => ['*!*@blocked.example', 'Other']);
    $a->is($r->{corrected}, 3, 'mb733-r2: ordinary ban, deop and restriction are all repaired');
    $a->is(scalar(@{ $normal_bans->{added} }), 1, 'mb733-r2: one durable sanction per abusive line');
    $a->is($normal_bans->{added}[0]{expires_seconds}, 600, 'mb733-r2: ten-minute ordinary sanction is unchanged');
    $a->is($normal->handle_join('#open', 'Newcomer'), 1, 'mb733-r2: every normal joiner still receives +o');
    $a->is($normal->handle_join('#open', 'Blocked', banned => 1), 0,
        'mb733-r2: an already banned joiner is not opped');

    my ($off, $off_bans, $off_sent) = mb733r2_guard(enabled => 0);
    $r = $off->handle_mode(channel => '#open', prefix => $official,
        mode_string => '+b', mode_args => ['*!*@blocked.example']);
    $a->is($r->{enabled}, 0, 'mb733-r2: channel opt-in remains mandatory');
    $equal->([$off_sent, $off_bans->{added}], [[], []], 'mb733-r2: disabled channels have no new action');
};
