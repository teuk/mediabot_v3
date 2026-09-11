use strict;
use warnings;
use Mediabot::Fullop;
use JSON::PP ();

{
    package MB733::Bans;
    sub new { bless { rows => [] }, shift }
    sub mask_from_hostmask {
        my ($self, $prefix) = @_;
        my (undef, $ident, $host) = $prefix =~ /^([^!]+)!([^@]+)\@(.+)$/;
        return "*!*$ident\@$host";
    }
    sub add_ban {
        my ($self, %row) = @_;
        push @{ $self->{rows} }, \%row;
        return (scalar(@{ $self->{rows} }), undef);
    }

    package MB733::Logger;
    sub log { push @{ $_[0]{lines} }, $_[2] }
}

sub mb733_guard {
    my (%opts) = @_;
    my (@sent, @said, @logs);
    my $bans = MB733::Bans->new;
    my $guard = Mediabot::Fullop->new(
        network => ($opts{network} // 'EpiKnet'),
        bot => { logger => bless({ lines => \@logs }, 'MB733::Logger') },
        enabled_cb => sub { exists($opts{enabled}) ? $opts{enabled} : 1 },
        privileged_cb => sub { 0 },
        channel_id_cb => sub { 42 },
        channel_ban => $bans,
        send_cb => sub { push @sent, [@_]; 1 },
        announce_cb => sub { push @said, [@_]; 1 },
        now_cb => sub { 1_000 },
        delegated_service_masks => ['Mirror!service@services.example'],
    );
    $guard->update_isupport(@{ $opts{isupport} // [
        'PREFIX=(qaohv)~&@%+', 'CHANMODES=beI,k,l,imnpst',
    ] });
    return ($guard, \@sent, \@said, $bans, \@logs);
}

sub mb733_mode {
    my ($guard, %opts) = @_;
    return $guard->handle_mode(
        channel => '#open',
        prefix => ($opts{prefix} // 'Cronos!services@olympe.epiknet.org'),
        mode_string => ($opts{mode} // '+qo'),
        mode_args => ($opts{args} // [ 'Founder', 'Founder' ]),
    );
}

return sub {
    my ($a) = @_;
    my $json = JSON::PP->new->canonical;
    my $same = sub { $a->is($json->encode($_[0]), $json->encode($_[1]), $_[2]) };

    # Reproduce the observed service +qo twice, including the durable sanction.
    my ($guard, $sent, $said, $bans, $logs) = mb733_guard();
    for my $attempt (1 .. 2) {
        my $r = mb733_mode($guard);
        $a->is($r->{sanctioned}, 0, "mb733: official +qo attempt $attempt has no sanction");
        $a->is($r->{corrected}, 0, "mb733: official +qo attempt $attempt is preserved");
        $a->is($r->{privileged}, 1, 'mb733-r2: official service authority also covers its rank grants');
    }
    $same->($sent, [], 'mb733: no inverse mode, service ban or kick for official +qo');
    $same->($said, [], 'mb733: no public admonishment for official +qo');
    $same->($bans->{rows}, [], 'mb733: no durable service sanction for official +qo');
    $a->like(join("\n", @$logs), qr/Fullop: accepted network service Cronos!services\@olympe\.epiknet\.org on #open modes=\+q\+o/,
        'mb733: accepted service rank is visible in the application debug log');
    $a->is($guard->{channel_state}{'#open'}{status}{q}{founder}, 'Founder',
        'mb733: official founder status is remembered');
    $a->is($guard->{channel_state}{'#open'}{status}{o}{founder}, 'Founder',
        'mb733: accompanying op status is remembered');

    for my $case (
        [ 'admin grant', { mode => '+a', args => ['Helper'] } ],
        [ 'multiple ranks', { mode => '+qa', args => ['Founder', 'Helper'] } ],
        [ 'case-insensitive exact identity', { prefix => 'cRoNoS!services@OLYMPE.EPIKNET.ORG' } ],
    ) {
        my ($g, $s, $p, $b) = mb733_guard();
        my $r = mb733_mode($g, %{ $case->[1] });
        $a->is($r->{sanctioned}, 0, "mb733: $case->[0] is accepted");
        $same->([$s, $p, $b->{rows}], [[], [], []], "mb733: $case->[0] has no side effect");
    }

    # Impersonators remain unprivileged. Mode ambiguity still cannot exempt
    # ordinary operators; official service decisions are covered in 1052.
    for my $case (
        [ 'ordinary actor', {}, { prefix => 'Visitor!person@users.example' } ],
        [ 'nickname-only impersonation', {}, { prefix => 'Cronos!person@users.example' } ],
        [ 'wrong ident', {}, { prefix => 'Cronos!visitor@olympe.epiknet.org' } ],
        [ 'wrong nickname', {}, { prefix => 'Other!services@olympe.epiknet.org' } ],
        [ 'host suffix spoof', {}, { prefix => 'Cronos!services@olympe.epiknet.org.example' } ],
        [ 'other network', { network => 'OtherNet' }, {} ],
        [ 'network substring spoof', { network => 'FakeEpiKnet' }, {} ],
        [ 'server network supersedes configuration', { isupport => [
            'NETWORK=OtherNet', 'PREFIX=(qaohv)~&@%+', 'CHANMODES=beI,k,l,imnpst',
        ] }, {} ],
        [ 'quiet list', { isupport => ['PREFIX=(ohv)@%+', 'CHANMODES=bqeI,k,l,imnpst'] },
            { prefix => 'Visitor!person@users.example', mode => '+q', args => ['*!*@users.example'] } ],
        [ 'missing status advertisement', { isupport => [] }, { prefix => 'Visitor!person@users.example' } ],
        [ 'withdrawn status advertisement', { isupport => ['PREFIX=(qaohv)~&@%+', '-PREFIX'] },
            { prefix => 'Visitor!person@users.example' } ],
        [ 'malformed replacement advertisement', { isupport => ['PREFIX=(qaohv)~&@%+', 'PREFIX=invalid'] },
            { prefix => 'Visitor!person@users.example' } ],
        [ 'missing target', {}, { prefix => 'Visitor!person@users.example', mode => '+q', args => [] } ],
        [ 'non-nickname target', {}, { prefix => 'Visitor!person@users.example', mode => '+q', args => ['*!*@users.example'] } ],
        [ 'deop', {}, { prefix => 'Visitor!person@users.example', mode => '-o', args => ['Visitor'] } ],
        [ 'founder removal', {}, { prefix => 'Visitor!person@users.example', mode => '-q', args => ['Founder'] } ],
        [ 'unrelated ban', {}, { prefix => 'Visitor!person@users.example', mode => '+b', args => ['*!*@users.example'] } ],
        [ 'channel restriction', {}, { prefix => 'Visitor!person@users.example', mode => '+m', args => [] } ],
    ) {
        my ($g, $s, $p, $b) = mb733_guard(%{ $case->[1] });
        my $r = mb733_mode($g, %{ $case->[2] });
        $a->is($r->{sanctioned}, 1, "mb733: $case->[0] retains Fullop policy");
        $a->is(scalar(@{ $b->{rows} }), 1, "mb733: $case->[0] is still recorded");
    }

    my ($mixed, $mixed_sent, undef, $mixed_bans) = mb733_guard();
    my $r = mb733_mode($mixed, mode => '+qob-o',
        args => ['Founder', 'Founder', '*!*@blocked.example', 'Visitor']);
    $a->is($r->{corrected}, 0, 'mb733-r2: mixed service line follows network authority');
    $a->is(scalar(@{ $mixed_bans->{rows} }), 0, 'mb733-r2: mixed service line causes no sanction');
    $same->($mixed_sent, [], 'mb733-r2: ranks and moderation by the service are preserved together');

    my ($delegated, $delegated_sent, undef, $delegated_bans) = mb733_guard();
    $delegated->authorize_delegated_ban(channel => '#open', mask => '*!*@blocked.example', ban_id => 9);
    mb733_mode($delegated);
    $r = mb733_mode($delegated, prefix => 'Mirror!service@services.example', mode => '+b', args => ['*!*@blocked.example']);
    $a->is($r->{delegated}, 1, 'mb733: service rank does not consume an authorized ban token');
    $same->([$delegated_sent, $delegated_bans->{rows}], [[], []],
        'mb733: separately authorized service mirror remains accepted');
    $r = mb733_mode($delegated, prefix => 'Mirror!service@services.example', mode => '+b', args => ['*!*@blocked.example']);
    $a->is($r->{sanctioned}, 1, 'mb733: ban token still cannot be replayed');

    my ($joins, $join_sent) = mb733_guard();
    $a->is($joins->handle_join('#open', 'Newcomer'), 1, 'mb733: Fullop still ops each new joiner');
    $same->($join_sent, [['MODE', undef, '#open', '+o', 'Newcomer']],
        'mb733: join auto-op is unchanged');
    my ($off, $off_sent) = mb733_guard(enabled => 0);
    $r = mb733_mode($off);
    $a->is($r->{enabled}, 0, 'mb733: other channels keep their Fullop opt-in');
    $same->($off_sent, [], 'mb733: disabled Fullop sends nothing');
};
