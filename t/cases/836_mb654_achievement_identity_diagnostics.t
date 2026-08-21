# t/cases/836_mb654_achievement_identity_diagnostics.t
# =============================================================================
# mb654 — read-only visibility for mb646 durable achievement identity profiles.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

sub slurp836 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

{
    package MB654DiagSTH;
    sub new { bless { rows => $_[1] || [], pos => 0, dbh => $_[2], sql => $_[3] }, $_[0] }
    sub execute {
        my ($self, @bind) = @_;
        push @{ $self->{dbh}{exec} }, [ $self->{sql}, @bind ];
        return 1;
    }
    sub fetchrow_hashref {
        my ($self) = @_;
        return undef if $self->{pos} >= @{ $self->{rows} };
        return $self->{rows}[ $self->{pos}++ ];
    }
    sub finish { 1 }

    package MB654DiagDBH;
    sub new { bless { mode => $_[1] || 'ok', sql => [], exec => [] }, $_[0] }
    sub prepare {
        my ($self, $sql) = @_;
        (my $flat = $sql) =~ s/\s+/ /g;
        $flat =~ s/^\s+|\s+$//g;
        push @{ $self->{sql} }, $flat;
        die "mb654 write attempted: $flat" unless $flat =~ /^SELECT\b/i;

        my @rows;
        if ($flat =~ /FROM CHANNEL\b/i) {
            @rows = ({ id_channel => 9, name => '#Test' });
        }
        elsif ($flat =~ /FROM ACHIEVEMENT_PROFILE p\b/i) {
            if ($self->{mode} eq 'ambiguous') {
                @rows = (
                    {
                        id_achievement_profile => 42, id_user => 7,
                        display_nick => 'Teuk', registered_nick => 'Teuk',
                        created_at => '2026-08-16 10:00:00', last_seen_at => '2026-08-17 10:00:00',
                        alias_count => 2, unlock_count => 17, progress_counters => 9,
                    },
                    {
                        id_achievement_profile => 99, id_user => undef,
                        display_nick => 'Teuk', registered_nick => undef,
                        created_at => '2026-08-15 10:00:00', last_seen_at => '2026-08-16 09:00:00',
                        alias_count => 1, unlock_count => 3, progress_counters => 2,
                    },
                );
            }
            elsif ($self->{mode} eq 'missing') {
                @rows = ();
            }
            else {
                @rows = ({
                    id_achievement_profile => 42, id_user => 7,
                    display_nick => 'Te[u]K', registered_nick => 'Teuk',
                    created_at => '2026-08-16 10:00:00', last_seen_at => '2026-08-17 10:00:00',
                    alias_count => 2, unlock_count => 17, progress_counters => 9,
                });
            }
        }
        elsif ($flat =~ /FROM ACHIEVEMENT_IDENTITY\b/i) {
            @rows = (
                { nick => 'Te[u]K', userhost => '~teuk@cloak.example', first_seen_at => '2026-08-16 10:00:00', last_seen_at => '2026-08-17 10:00:00' },
                { nick => 'Teuk',   userhost => 'teuk@cloak.example',  first_seen_at => '2026-08-15 09:00:00', last_seen_at => '2026-08-16 11:00:00' },
            );
        }
        return MB654DiagSTH->new(\@rows, $self, $flat);
    }
}

return sub {
    my ($assert) = @_;

    require Mediabot::Achievements;

    # [1] One durable profile: current DB evidence is rendered without writes.
    my $dbh = MB654DiagDBH->new('ok');
    my $ach = bless {
        storage => 'db',
        bot => { dbh => $dbh },
    }, 'Mediabot::Achievements';

    my $d = $ach->identity_profile_diagnostic('Teuk', '#test');
    $assert->is($d->{status}, 'ok',
        'mb654-836: unique nick candidate resolves to one diagnostic profile');
    $assert->is($d->{profile}{id_achievement_profile}, 42,
        'mb654-836: diagnostic exposes durable profile id');
    $assert->is($d->{profile}{id_user}, 7,
        'mb654-836: diagnostic exposes registered USER anchor');
    $assert->is($d->{profile}{registered_nick}, 'Teuk',
        'mb654-836: diagnostic exposes registered USER nickname');
    $assert->is($d->{profile}{unlock_count}, 17,
        'mb654-836: diagnostic reports unlock count');
    $assert->is($d->{profile}{progress_counters}, 9,
        'mb654-836: diagnostic reports progress counter count');
    $assert->is(scalar(@{ $d->{aliases} }), 2,
        'mb654-836: diagnostic returns durable aliases');
    $assert->is($d->{aliases}[0]{nick}, 'Te[u]K',
        'mb654-836: aliases preserve current display spelling');
    $assert->ok($d->{resolution_evidence}{nick_query_unique},
        'mb654-836: result identifies unique nick evidence');
    $assert->ok($d->{resolution_evidence}{registered_user},
        'mb654-836: result identifies registered USER evidence');
    $assert->is($d->{historical_reason}, 'not_persisted',
        'mb654-836: diagnostic refuses to invent a historical merge reason');

    my $all_sql = join("\n", @{ $dbh->{sql} });
    $assert->ok($all_sql ne '', 'mb654-836: DB diagnostic executes queries');
    $assert->ok(!(scalar grep { $_ !~ /^SELECT\b/i } @{ $dbh->{sql} }),
        'mb654-836: every prepared diagnostic statement is SELECT-only');
    $assert->unlike($all_sql, qr/\b(?:INSERT|UPDATE|DELETE|REPLACE|ALTER|CREATE|DROP)\b/i,
        'mb654-836: diagnostic SQL contains no mutation verb');
    $assert->like($all_sql, qr/LIMIT 20/i,
        'mb654-836: alias rendering is bounded at the SQL source');
    $assert->like($all_sql, qr/LIMIT 21/i,
        'mb654-836: ambiguous candidate discovery is bounded at the SQL source');

    # [2] A nick matching two profiles stays ambiguous instead of guessing.
    my $amb_dbh = MB654DiagDBH->new('ambiguous');
    my $amb = bless {
        storage => 'db', bot => { dbh => $amb_dbh },
    }, 'Mediabot::Achievements';
    my $ad = $amb->identity_profile_diagnostic('Teuk', '#test');
    $assert->is($ad->{status}, 'ambiguous',
        'mb654-836: multiple plausible profiles are reported as ambiguous');
    $assert->is(scalar(@{ $ad->{candidates} }), 2,
        'mb654-836: ambiguity returns every candidate profile');
    $assert->ok(!(scalar grep { /SELECT nick, userhost, first_seen_at, last_seen_at FROM ACHIEVEMENT_IDENTITY/i } @{ $amb_dbh->{sql} }),
        'mb654-836: ambiguity stops before selecting/loading one alias set');

    # [3] Missing nick is read-only and explicit.
    my $miss_dbh = MB654DiagDBH->new('missing');
    my $miss = bless {
        storage => 'db', bot => { dbh => $miss_dbh },
    }, 'Mediabot::Achievements';
    my $md = $miss->identity_profile_diagnostic('Nobody', '#test');
    $assert->is($md->{status}, 'not_found',
        'mb654-836: absent nick returns not_found rather than creating a profile');

    # [4] Legacy JSON reports its real identity model instead of pretending DB
    # profile/alias semantics exist.
    my $key = "teuk\x00#test";
    my $legacy = bless {
        storage => 'json',
        data => { $key => { first_msg => 1, chatterbox => 2 } },
        progress => {
            msg_count => { $key => 123 },
            trivia_wins => { $key => 5 },
        },
    }, 'Mediabot::Achievements';
    my $ld = $legacy->identity_profile_diagnostic('Teuk', '#Test');
    $assert->is($ld->{status}, 'legacy_json',
        'mb654-836: legacy storage is reported explicitly');
    $assert->is($ld->{unlock_count}, 2,
        'mb654-836: legacy diagnostic reports unlock count read-only');
    $assert->is($ld->{progress_counters}, 2,
        'mb654-836: legacy diagnostic reports progress counter count read-only');

    # [5] Partyline is only a bounded renderer around the Achievements API.
    my $pl = slurp836('Mediabot/Partyline.pm') . "\n" . slurp836('Mediabot/Partyline/Dispatcher.pm') . "\n" . slurp836('Mediabot/Partyline/Commands.pm');
    $assert->like($pl,
        qr/^\s*elsif \(\$line =~ \/\^\\\.achievementprofile/m,
        'mb654-836: Partyline dispatches .achievementprofile');
    $assert->like($pl,
        qr/_cmd_achievementprofile\(\$stream, \$id, \$1\)/,
        'mb654-836: Partyline route forwards command arguments');
    $assert->like($pl,
        qr/identity_profile_diagnostic\(\$nick, \$channel\)/,
        'mb654-836: Partyline delegates identity truth to Achievements');
    $assert->like($pl,
        qr/Achievement identity diagnostic \(read-only\)/,
        'mb654-836: operator output labels the command read-only');
    $assert->like($pl,
        qr/historical merge reasons; this shows current durable evidence only/,
        'mb654-836: Partyline does not invent merge history');
    $assert->like($pl,
        qr/\.achievementprofile <nick> <#chan>/,
        'mb654-836: Partyline help advertises the diagnostic command');

    # [6] The implementation must not route through mutating identity helpers.
    my $src = slurp836('Mediabot/Achievements.pm');
    my ($body) = $src =~ /(sub identity_profile_diagnostic \{.*?\n\})\n\nsub storage_stats/s;
    $assert->ok(defined($body),
        'mb654-836: identity diagnostic method body is discoverable');
    if (defined $body) {
        $assert->unlike($body, qr/->observe_identity\s*\(/,
            'mb654-836: diagnostic never observes/touches a live identity');
        $assert->unlike($body, qr/->_profile_id_for\s*\(/,
            'mb654-836: diagnostic never uses profile lookup that can cache/create');
        $assert->unlike($body, qr/->_channel_id\s*\(/,
            'mb654-836: diagnostic avoids the mutating channel cache helper');
        $assert->unlike($body, qr/->_(?:attach_identity|touch_profile|touch_seen_alias|merge_profiles|create_profile)\s*\(/,
            'mb654-836: diagnostic never calls any persistence mutation helper');
    }
};
