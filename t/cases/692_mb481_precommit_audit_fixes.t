# t/cases/692_mb481_precommit_audit_fixes.t
# mb481 — precommit audit fixes after MB480.
# Scan-only regression: SQL literal quoting in db_install, IRC channel-prefix
# consistency for new factoid/didyoumean code, and UTF-8-safe factoid value cap.
#
# Rewritten to the project's closure/$assert convention (was self-printing +
# exit 0, which broke the harness's isolated TAP parse).

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_692 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($FindBin::Bin, '..', '..');

    # --- 1. db_install.sh : SQL literal quoting of a custom DB password -------
    my $db = _slurp_692(File::Spec->catfile($root, 'install', 'db_install.sh'));
    $assert->like($db, qr/sql_string_literal\(\)\s*\{/,
        'db_install defines sql_string_literal');
    $assert->like($db, qr/MYSQL_DB_PASS_SQL=\$\(sql_string_literal "\$MYSQL_DB_PASS"\)/,
        'db password is converted to an SQL literal');
    $assert->like($db, qr/IDENTIFIED BY \$\{MYSQL_DB_PASS_SQL\}/,
        'CREATE/ALTER USER uses the quoted password literal');
    $assert->unlike($db, qr/IDENTIFIED BY '\$\{MYSQL_DB_PASS\}'/,
        'raw MYSQL_DB_PASS is not embedded in SQL');
    $assert->like($db, qr/newline characters are not allowed/,
        'newline-bearing custom passwords are rejected explicitly');

    # --- 2. factoid code: shared IRC channel predicate + UTF-8-safe cap ------
    my $uc = _slurp_692(File::Spec->catfile($root, 'Mediabot', 'UserCommands.pm'));
    my ($factoid) = $uc =~ /(Factoids .+?shared per-channel key\/value facts.*?\n1;)/s;
    $factoid //= '';
    $assert->like($factoid, qr/isIrcChannelTarget\(\$channel\)/,
        'factoid code uses the shared IRC channel-target predicate');
    $assert->unlike($factoid, qr/\$channel\s*=~\s*\/\^#\//,
        'factoid code does not hard-code # as the only channel prefix');
    $assert->like($factoid, qr/truncate_utf8\(\$value,\s*400,\s*''\)/,
        'factoid value cap is UTF-8-safe');
    $assert->unlike($factoid, qr/substr\(\$value,\s*0,\s*400\)/,
        'factoid value cap no longer uses raw substr');

    # --- 3. did-you-mean: shared IRC channel predicate ----------------------
    my $med = _slurp_692(File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm'));
    my ($suggest) = $med =~ /(sub _mbSuggestCommand \{.*?\n\})/s;
    $suggest //= '';
    $assert->like($suggest, qr/Mediabot::Helpers::isIrcChannelTarget\(\$channel\)/,
        'did-you-mean uses shared channel-target predicate');
    $assert->unlike($suggest, qr/\$channel\s*=~\s*\/\^#\//,
        'did-you-mean no longer hard-codes # only');
};
