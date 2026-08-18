# t/cases/845_mb664_channel_memory.t
# =============================================================================
# mb664 step 1 — bounded Channel Memory selector foundation.
#
# The public command is wired only after this query contract is validated.
# =============================================================================
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Mediabot::UserCommands;

sub _slurp_845 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;
    my $src = _slurp_845(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my ($fn) = $src =~ /(sub _memory_lines \{.*?\n\})\n\n# ===========================================================================\n# mbMilestone_ctx/s;
    $fn //= '';

    $assert->like($src, qr/sub _memory_lines \{/, 'mb664-845: memory helper exists');
    $assert->unlike($fn, qr/ORDER\s+BY\s+RAND\s*\(/i, 'mb664-845: never ORDER BY RAND()');
    $assert->like($fn, qr/channel_log_gather\(/, 'mb664-845: reuses archive-aware gather source of truth');
    $assert->like($fn, qr/'content'\)/, 'mb664-845: archive content policy is respected');
    $assert->like($fn, qr/ts < CURDATE\(\) - INTERVAL 30 DAY/, 'mb664-845: recent 30 days excluded');
    $assert->like($fn, qr/ts >= FROM_UNIXTIME\(\?\)/, 'mb664-845: selection uses indexed timestamp seek');
    $assert->like($fn, qr/ts >= \?\s+AND ts < DATE_ADD\(\?, INTERVAL 1 DAY\)/s,
        'mb664-845: concrete day uses sargable range');
    $assert->like($fn, qr/LIMIT 40/, 'mb664-845: quote candidates are bounded');
    $assert->like($fn, qr/\$attempts = 6 if \$attempts > 6/, 'mb664-845: retry budget is bounded');

    my @scopes;
    {
        no warnings 'redefine';
        local *Mediabot::Helpers::channel_log_gather = sub {
            my ($self,$dbh,$sql,$bind,$cb,$scope)=@_;
            push @scopes, $scope;
            if ($sql =~ /ORDER BY ts ASC/ && $sql =~ /LIMIT 1/ && $sql !~ /FROM_UNIXTIME/) {
                $cb->({ ts=>'2024-08-19 03:25:58', uts=>1724037958 }, 'CHANNEL_LOG');
                $cb->({ ts=>'2018-06-03 07:13:08', uts=>1528009988 }, 'archive.CHANNEL_LOG_ARCHIVE');
            }
            elsif ($sql =~ /ORDER BY ts DESC/ && $sql =~ /LIMIT 1/) {
                $cb->({ ts=>'2026-07-18 16:27:05', uts=>1784392025 }, 'CHANNEL_LOG');
                $cb->({ ts=>'2024-08-15 04:17:33', uts=>1723695453 }, 'archive.CHANNEL_LOG_ARCHIVE');
            }
            elsif ($sql =~ /FROM_UNIXTIME\(\?\)/ && $sql =~ /LIMIT 1/) {
                $cb->({ ts=>'2024-08-19 03:25:58', uts=>1724037958 }, 'CHANNEL_LOG');
                $cb->({ ts=>'2021-02-01 16:58:26', uts=>1612198706 }, 'archive.CHANNEL_LOG_ARCHIVE');
            }
            elsif ($sql =~ /COUNT\(\*\) AS msgs/) {
                $cb->({ msgs=>0, people=>0 }, 'CHANNEL_LOG');
                $cb->({ msgs=>19, people=>4 }, 'archive.CHANNEL_LOG_ARCHIVE');
            }
            elsif ($sql =~ /GROUP BY nick/) {
                $cb->({ nick=>'sweetykatou', c=>9 }, 'archive.CHANNEL_LOG_ARCHIVE');
                $cb->({ nick=>'fool', c=>5 }, 'archive.CHANNEL_LOG_ARCHIVE');
            }
            elsif ($sql =~ /CHAR_LENGTH\(publictext\) BETWEEN 25 AND 300/) {
                $cb->({ ts=>'2021-02-01 18:00:00', nick=>'fool', event_type=>'public',
                    publictext=>'this old channel line is long enough to become a memory' },
                    'archive.CHANNEL_LOG_ARCHIVE');
            }
            return { live_ok=>1, tainted=>0 };
        };
        local *Mediabot::Helpers::truncate_utf8 = sub { $_[0] };
        use warnings 'redefine';

        my $bot = bless { dbh=>bless({},'DBH845'), logger=>bless({},'Log845') }, 'Mediabot';
        my @lines = Mediabot::UserCommands::_memory_lines(
            $bot, 13, '#miaw', attempts=>1, rand_cb=>sub { 0 }
        );
        my $joined = join("\n", @lines);
        $assert->like($joined,
            qr/Memory from #miaw .* 2021-02-01: 19 messages, 4 people, most active: sweetykatou\./,
            'mb664-845: archive day summary is rendered');
        $assert->like($joined,
            qr/<fool> this old channel line is long enough to become a memory/,
            'mb664-845: representative quote is rendered');
    }
    $assert->ok(
        @scopes && !grep({ $_ ne 'content' } @scopes),
        'mb664-845: every history query uses content scope',
    );
};
