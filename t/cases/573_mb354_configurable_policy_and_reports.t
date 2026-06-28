# t/cases/573_mb354_configurable_policy_and_reports.t
# mb354 — operational thresholds and report slots are configurable safely.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

BEGIN {
    unshift @INC, "$Bin/../..";
    package Config::Simple;
    sub import { }
    sub new { bless {}, shift }
    sub vars { return () }
    sub param { return 1 }
    sub write { return 1 }
    $INC{'Config/Simple.pm'} = __FILE__;
}

require Mediabot::Conf;

my $conf = Mediabot::Conf->new({
    'main.OK'       => ' 42 ',
    'main.LOW'      => '-50',
    'main.HIGH'     => '99999',
    'main.BAD'      => '12x',
    'main.REF'      => [ 12 ],
    'main.NEGATIVE' => '-3',
});

is($conf->get_int('main.OK', default => 7, min => 0, max => 100), 42,
    'valid integer is returned');
is($conf->get_int('main.MISSING', default => 7, min => 0, max => 100), 7,
    'missing value falls back');
is($conf->get_int('main.BAD', default => 7, min => 0, max => 100), 7,
    'malformed value falls back');
is($conf->get_int('main.REF', default => 7, min => 0, max => 100), 7,
    'reference value falls back');
is($conf->get_int('main.LOW', default => 7, min => 0, max => 100), 0,
    'numeric value below range is clamped');
is($conf->get_int('main.HIGH', default => 7, min => 0, max => 100), 100,
    'numeric value above range is clamped');
is($conf->get_int('main.NEGATIVE', default => 7, min => -10, max => 10), -3,
    'signed integer is accepted');

my $missing_default = eval {
    $conf->get_int('main.OK', min => 0, max => 100);
    1;
};
ok(!$missing_default, 'get_int requires an explicit default');
like($@, qr/default required/, 'missing default has a clear diagnostic');

my $bad_range = eval {
    $conf->get_int('main.OK', default => 7, min => 100, max => 10);
    1;
};
ok(!$bad_range, 'get_int rejects inverted bounds');
like($@, qr/min cannot be greater than max/, 'inverted bounds have a clear diagnostic');

sub slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

my $partyline = slurp('Mediabot/Partyline.pm');
for my $key (qw(
    PARTYLINE_LOGIN_MAX_FAILURES
    PARTYLINE_LOGIN_IP_MAX_FAILURES
    PARTYLINE_LOGIN_IP_WINDOW_SECONDS
    PARTYLINE_LOGIN_IP_MAX_ENTRIES
)) {
    like($partyline, qr/\Q$key\E/, "Partyline reads $key");
}
like($partyline, qr/default\s*=>\s*5,\s*min\s*=>\s*1,\s*max\s*=>\s*100/,
    'per-connection failure count has safe bounds');
like($partyline, qr/default\s*=>\s*15,\s*min\s*=>\s*1,\s*max\s*=>\s*1000/,
    'per-IP failure count has safe bounds');
like($partyline, qr/default\s*=>\s*600,\s*min\s*=>\s*30,\s*max\s*=>\s*86400/,
    'per-IP window has safe bounds');
like($partyline, qr/default\s*=>\s*1024,\s*min\s*=>\s*16,\s*max\s*=>\s*65536/,
    'per-IP map limit has safe bounds');

my $quotes = slurp('Mediabot/Quotes.pm');
like($quotes, qr/QUOTE_DELETE_CHANNEL_LEVEL/,
    'quote deletion threshold is configurable');
like($quotes, qr/default\s*=>\s*100,\s*min\s*=>\s*0,\s*max\s*=>\s*500/,
    'quote deletion threshold has safe bounds');
like($quotes, qr/checkUserChannelLevel\([^)]*\$quote_delete_level\)/,
    'effective quote threshold reaches authorization check');
like($quotes, qr/channel level >= \$quote_delete_level/,
    'user-facing refusal reports the effective threshold');

my $main = slurp('mediabot.pl');
for my $key (qw(
    REPORT_DAILY_HOUR
    REPORT_DAILY_MINUTE
    REPORT_WEEKLY_WDAY
    REPORT_WEEKLY_HOUR
    REPORT_WEEKLY_MINUTE
)) {
    like($main, qr/\Q$key\E/, "main reads $key");
}
like($main, qr/_next_daily_epoch\(\s*\$_\[0\],\s*\$report_daily_hour,\s*\$report_daily_minute/s,
    'daily calendar callback uses configured slot');
like($main, qr/_next_weekly_epoch\(\s*\$_\[0\],\s*\$report_weekly_wday,\s*\$report_weekly_hour,\s*\$report_weekly_minute/s,
    'weekly calendar callback uses configured slot');
like($main, qr/Report schedule: daily=.*timezone=%s/,
    'effective report schedule and timezone are logged');
like($main, qr/strftime\('%Z %z'/,
    'report timezone is derived explicitly from process localtime');

my $sample = slurp('mediabot.sample.conf');
my %defaults = (
    PARTYLINE_LOGIN_MAX_FAILURES         => 5,
    PARTYLINE_LOGIN_IP_MAX_FAILURES      => 15,
    PARTYLINE_LOGIN_IP_WINDOW_SECONDS    => 600,
    PARTYLINE_LOGIN_IP_MAX_ENTRIES       => 1024,
    QUOTE_DELETE_CHANNEL_LEVEL           => 100,
    REPORT_DAILY_HOUR                    => 0,
    REPORT_DAILY_MINUTE                  => 0,
    REPORT_WEEKLY_WDAY                   => 1,
    REPORT_WEEKLY_HOUR                   => 0,
    REPORT_WEEKLY_MINUTE                 => 0,
);
for my $key (sort keys %defaults) {
    like($sample, qr/^\Q$key\E=\Q$defaults{$key}\E$/m,
        "sample documents $key with backward-compatible default");
}

my $conf_src = slurp('Mediabot/Conf.pm');
like($conf_src, qr/sub get_int/, 'central integer config guard is present');
like($conf_src, qr/mb354|validated integer configuration/s,
    'configuration validation is documented in source');

done_testing();
