# t/cases/692_mb481_precommit_audit_fixes.t
# mb481 — precommit audit fixes after MB480.
# Scan-only regression: SQL literal quoting in db_install, IRC channel-prefix
# consistency for new factoid/didyoumean code, and UTF-8-safe factoid value cap.

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

my ($ok, $fail) = (0, 0);
sub _pass { my ($msg)=@_; print "  [PASS] $msg\n"; $ok++ }
sub _fail { my ($msg,$got)=@_; print "  [FAIL] $msg" . (defined $got ? " ($got)" : "") . "\n"; $fail++ }
sub _like { my ($s,$re,$msg)=@_; $s =~ $re ? _pass($msg) : _fail($msg) }
sub _not_like { my ($s,$re,$msg)=@_; $s !~ $re ? _pass($msg) : _fail($msg) }
sub _slurp { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

my $root = File::Spec->catdir($FindBin::Bin, '..', '..');

my $db = _slurp(File::Spec->catfile($root, 'install', 'db_install.sh'));
_like($db, qr/sql_string_literal\(\)\s*\{/, 'db_install defines sql_string_literal');
_like($db, qr/MYSQL_DB_PASS_SQL=\$\(sql_string_literal "\$MYSQL_DB_PASS"\)/, 'db password is converted to an SQL literal');
_like($db, qr/IDENTIFIED BY \$\{MYSQL_DB_PASS_SQL\}/, 'CREATE/ALTER USER uses the quoted password literal');
_not_like($db, qr/IDENTIFIED BY '\$\{MYSQL_DB_PASS\}'/, 'raw MYSQL_DB_PASS is not embedded in SQL');
_like($db, qr/newline characters are not allowed/, 'newline-bearing custom passwords are rejected explicitly');

my $uc = _slurp(File::Spec->catfile($root, 'Mediabot', 'UserCommands.pm'));
my ($factoid) = $uc =~ /(Factoids .+?shared per-channel key\/value facts.*?\n1;)/s;
$factoid //= '';
_like($factoid, qr/isIrcChannelTarget\(\$channel\)/, 'factoid code uses the shared IRC channel-target predicate');
_not_like($factoid, qr/\$channel\s*=~\s*\/\^#\//, 'factoid code does not hard-code # as the only channel prefix');
_like($factoid, qr/truncate_utf8\(\$value,\s*400,\s*''\)/, 'factoid value cap is UTF-8-safe');
_not_like($factoid, qr/substr\(\$value,\s*0,\s*400\)/, 'factoid value cap no longer uses raw substr');

my $med = _slurp(File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm'));
my ($suggest) = $med =~ /(sub _mbSuggestCommand \{.*?\n\})/s;
$suggest //= '';
_like($suggest, qr/Mediabot::Helpers::isIrcChannelTarget\(\$channel\)/, 'did-you-mean uses shared channel-target predicate');
_not_like($suggest, qr/\$channel\s*=~\s*\/\^#\//, 'did-you-mean no longer hard-codes # only');

print "\n============================================================\n";
if ($fail) { print "FAILED : $fail/" . ($ok + $fail) . "  ($ok passed)\n"; exit 1; }
print "PASSED : $ok/$ok\n";
print "============================================================\n";
exit 0;
