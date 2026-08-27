use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
return sub {
 my($assert)=@_; open my $fh,'<:encoding(UTF-8)',"$Bin/../../mediabot.pl" or die $!; local $/; my $m=<$fh>;
 $assert->like($m,qr/use Mediabot::VDM::Runtime \(\);/,'mb704-983: top-level Spark runtime imports VDM facade only');
 $assert->like($m,qr/chanset_enabled\(\$bot, \$channel, 'VDM', default => 0\)/,'mb704-983: Spark tick reads +VDM default-off');
 $assert->like($m,qr/vdm_enabled\s*=>\s*\$vdm_enabled/,'mb704-983: +VDM eligibility is passed into deterministic selector');
 $assert->like($m,qr/\(\$summary->\{kind\} \/\/ ''\) eq 'vdm'/,'mb704-983: VDM branches before provider-neutral AI generation');
 $assert->like($m,qr/request_spark\(/,'mb704-983: Spark VDM uses shared asynchronous VDM runtime');
 $assert->like($m,qr/activity_current_cb\s*=>\s*sub/,'mb704-983: new human activity gets an explicit late-revocation gate');
 $assert->like($m,qr/_spark_handle_vdm_candidate\(/,'mb704-983: VDM source completion reaches dedicated guarded Spark delivery adapter');
 my($tick)=$m=~/(sub _spark_tick_all \{.*?\n\})\n\n# \+---/s;
 $assert->ok(defined $tick,'mb704-983: Spark tick remains structurally locatable');
 $assert->unlike($tick//' ',qr/\b(?:botPrivmsg|botNotice|send_message|do_PRIVMSG)\b/,'mb704-983: Spark tick still owns no IRC transport primitive');
};
