# t/cases/851_mb669_durable_identity_api.t
# =============================================================================
# mb669 — public read-only Durable Identity API.
# =============================================================================
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{
    package Stmt851;
    sub new { bless { kind => $_[1], dbh => $_[2], rows => [], pos => 0 }, $_[0] }
    sub execute {
        my ($self, @bind) = @_;
        push @{ $self->{dbh}{execs} }, [ $self->{kind}, @bind ];
        my $mode = $self->{dbh}{mode};
        if ($self->{kind} eq 'direct') {
            if ($mode eq 'channel_missing') {
                $self->{rows} = [];
            }
            elsif ($mode eq 'direct') {
                $self->{rows} = [{
                    id_channel => 9, channel_name => '#fixture',
                    id_user => 7, registered_nick => 'RegisteredFixture',
                }];
            }
            else {
                $self->{rows} = [{
                    id_channel => 9, channel_name => '#fixture',
                    id_user => undef, registered_nick => undef,
                }];
            }
        }
        elsif ($self->{kind} eq 'alias') {
            if ($mode eq 'alias_unique') {
                $self->{rows} = [{
                    id_user => 42, registered_nick => 'DurableFixture',
                    id_achievement_profile => 101, last_seen_at => '2026-08-19 10:00:00',
                }];
            }
            elsif ($mode eq 'alias_ambiguous') {
                $self->{rows} = [
                    { id_user => 42, registered_nick => 'FirstFixture',
                      id_achievement_profile => 101, last_seen_at => '2026-08-19 10:00:00' },
                    { id_user => 43, registered_nick => 'SecondFixture',
                      id_achievement_profile => 102, last_seen_at => '2026-08-19 09:00:00' },
                ];
            }
            else {
                $self->{rows} = [];
            }
        }
        elsif ($self->{kind} eq 'aliases') {
            $self->{rows} = [
                { nick => 'AliasTwo', userhost => 'u@host2',
                  first_seen_at => '2026-01-02', last_seen_at => '2026-08-19' },
                { nick => 'AliasOne', userhost => 'u@host1',
                  first_seen_at => '2026-01-01', last_seen_at => '2026-08-18' },
            ];
        }
        $self->{pos} = 0;
        return 1;
    }
    sub fetchrow_hashref {
        my ($self) = @_;
        return undef if $self->{pos} >= @{ $self->{rows} };
        return $self->{rows}[ $self->{pos}++ ];
    }
    sub finish { 1 }
}

{
    package DBH851;
    sub new { bless { mode => $_[1], sql => [], execs => [] }, $_[0] }
    sub can { $_[1] eq 'prepare' ? 1 : UNIVERSAL::can($_[0], $_[1]) }
    sub prepare {
        my ($self, $sql) = @_;
        push @{ $self->{sql} }, $sql;
        return Stmt851->new('direct', $self)
            if $sql =~ /FROM CHANNEL c\s+LEFT JOIN USER u/s;
        return Stmt851->new('alias', $self)
            if $sql =~ /FROM ACHIEVEMENT_PROFILE p\s+LEFT JOIN ACHIEVEMENT_IDENTITY i/s;
        return Stmt851->new('aliases', $self)
            if $sql =~ /FROM ACHIEVEMENT_PROFILE p\s+JOIN ACHIEVEMENT_IDENTITY i/s;
        die "mb669-851 unexpected SQL: $sql";
    }
}

sub fake851 {
    my ($mode) = @_;
    my $dbh = DBH851->new($mode);
    my $ach = bless { storage => 'db', bot => { dbh => $dbh } }, 'Mediabot::Achievements';
    return ($ach, $dbh);
}

sub slurp851 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub sub_src851 {
    my ($src, $name) = @_;
    my $start = index($src, "sub $name {");
    return undef if $start < 0;
    my $next = index($src, "\nsub ", $start + 5);
    $next = length($src) if $next < 0;
    return substr($src, $start, $next - $start);
}

return sub {
    my ($assert) = @_;
    require Mediabot::Achievements;

    {
        my ($ach, $dbh) = fake851('direct');
        my $r = $ach->resolve_registered_user('#fixture', 'RegisteredFixture');
        $assert->is($r->{status}, 'ok', 'mb669-851: exact registered user resolves');
        $assert->is($r->{source}, 'registered_nick', 'mb669-851: exact USER nickname is authoritative');
        $assert->is($r->{id_user}, 7, 'mb669-851: exact USER id is returned');
        $assert->is(scalar @{ $dbh->{sql} }, 1, 'mb669-851: exact path needs one SELECT');
    }

    {
        my ($ach, $dbh) = fake851('alias_unique');
        my $r = $ach->resolve_registered_user('#fixture', 'AliasFixture');
        $assert->is($r->{status}, 'ok', 'mb669-851: unique durable alias resolves');
        $assert->is($r->{source}, 'durable_alias', 'mb669-851: durable alias source is explicit');
        $assert->is($r->{id_user}, 42, 'mb669-851: durable alias returns registered USER id');
        $assert->is($r->{id_achievement_profile}, 101, 'mb669-851: durable profile id is exposed');
        $assert->is(scalar @{ $dbh->{sql} }, 2, 'mb669-851: alias path is bounded to two SELECTs');
    }

    {
        my ($ach, $dbh) = fake851('alias_ambiguous');
        my $r = $ach->resolve_registered_user('#fixture', 'SharedFixture');
        $assert->is($r->{status}, 'ambiguous', 'mb669-851: ambiguous alias is not guessed');
        $assert->is(scalar @{ $r->{candidates} }, 2, 'mb669-851: ambiguity returns the two bounded candidates');
        $assert->ok(!exists($r->{id_user}), 'mb669-851: ambiguous result exposes no chosen USER id');
    }

    {
        my ($ach, $dbh) = fake851('alias_unique');
        my $r = $ach->known_aliases('#fixture', 'AliasFixture', 8);
        $assert->is($r->{status}, 'ok', 'mb669-851: known_aliases preserves successful resolution');
        $assert->is(scalar @{ $r->{aliases} }, 2, 'mb669-851: known_aliases returns bounded durable aliases');
        $assert->is($r->{aliases}[0]{nick}, 'AliasTwo', 'mb669-851: alias order is preserved');
        my $all = join "\n", @{ $dbh->{sql} };
        $assert->like($all, qr/LIMIT 8\b/, 'mb669-851: caller alias limit is SQL-bounded');
    }

    {
        my ($ach) = fake851('channel_missing');
        my $r = $ach->resolve_registered_user('#missing', 'Nobody');
        $assert->is($r->{status}, 'channel_not_found', 'mb669-851: missing channel is explicit');
    }

    {
        my $ach = bless { storage => 'json', data => {}, progress => {} }, 'Mediabot::Achievements';
        my $r = $ach->resolve_registered_user('#fixture', 'LegacyFixture');
        $assert->is($r->{status}, 'legacy_json', 'mb669-851: legacy backend reports unsupported durable graph');
    }

    my $src = slurp851('Mediabot/Achievements.pm');
    my $resolve = sub_src851($src, 'resolve_registered_user');
    my $aliases = sub_src851($src, 'known_aliases');
    $assert->ok(defined($resolve) && defined($aliases), 'mb669-851: both public identity API methods exist');

    for my $body ($resolve, $aliases) {
        my @sql = ($body =~ /(?:prepare|do)\s*\(\s*(?:q[qwxr]?|qq)?\s*\{(.*?)\}\s*\)/sg);
        $assert->unlike($body, qr/\b(?:INSERT|UPDATE|DELETE|REPLACE)\b/i,
            'mb669-851: identity API contains no SQL mutation verb');
        $assert->unlike($body, qr/->(?:observe_identity|_profile_id_for|_attach_identity|_touch_profile|_merge_profiles)\s*\(/,
            'mb669-851: identity API calls no mutating identity helper');
    }

    my $uc = slurp851('Mediabot/UserCommands.pm');
    $assert->unlike($uc, qr/ACHIEVEMENT_(?:PROFILE|IDENTITY)/,
        'mb669-851: UserCommands has no private durable-identity table dependency');
    $assert->like($uc, qr/resolve_registered_user\(\$channel,\s*\$target\)/,
        'mb669-851: Community Footprint consumes the public identity API');
};
