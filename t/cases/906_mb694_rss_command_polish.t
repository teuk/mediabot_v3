# t/cases/906_mb694_rss_command_polish.t
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
sub _slurp906 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; return <$fh>; }
return sub {
    my ($assert)=@_;
    my $cmd=_slurp906('Mediabot/RSS/Commands.pm');
    my $repo=_slurp906('Mediabot/RSS/Repository.pm');
    my $rss=_slurp906('Mediabot/RSS.pm');
    my $mb=_slurp906('Mediabot/Mediabot.pm');
    $assert->like($cmd, qr/format_rss_feed_overview\(\$channel, @\$rows\)/, 'mb694-906: list uses operational overview');
    $assert->like($cmd, qr/format_rss_feed_info_lines\(\$feed\)/, 'mb694-906: info uses operational detail view');
    $assert->like($cmd, qr/first poll is silent/, 'mb694-906: add sets first-poll expectation');
    $assert->like($cmd, qr/interval must be between 5 and 1440 minutes/, 'mb694-906: interval range is explicit');
    $assert->like($cmd, qr/max must be between 1 and 10 articles per poll/, 'mb694-906: max range is explicit');
    $assert->like($cmd, qr/enabled accepts on\/off, yes\/no or 1\/0/, 'mb694-906: enabled values are explicit');
    $assert->like($cmd, qr/private, loopback or reserved IP addresses are not allowed/, 'mb694-906: URL policy error is user-facing');
    $assert->like($cmd, qr/Automatic polling: the first successful poll is silent/, 'mb694-906: help explains automatic polling');
    $assert->like($repo, qr/SUM\(CASE WHEN ri\.id_rss_item IS NOT NULL AND ri\.announced_at IS NULL.*?AS pending_count/s, 'mb694-906: repository derives pending count');
    $assert->like($repo, qr/MAX\(CASE WHEN rf\.last_poll_at IS NULL.*?TIMESTAMPDIFF\(SECOND, NOW\(\),\s*TIMESTAMPADD\(SECOND, rf\.poll_interval, rf\.last_poll_at\)\).*?AS next_poll_in/s, 'mb694-906: repository derives next-poll delay');
    $assert->like($rss, qr/sub rss_feed_state .*?waiting.*?pending.*?ok/s, 'mb694-906: health-state policy is centralized');
    $assert->like($mb, qr/^rss\|rss <list\|info\|add\|del\|set\|probe\|show> .*automatic polling; first poll is silent/m, 'mb694-906: internal help reflects automatic RSS');
    $assert->unlike($cmd.$repo.$rss, qr/CREATE TABLE|ALTER TABLE|CREATE INDEX|DROP TABLE/, 'mb694-906: UX polish has no schema operation');
    $assert->like($rss, qr/sub format_rss_announcement .*?ACTION - news .*?\\00313\[\$label\]/s, 'mb694-906: article ACTION charter remains present');
};
