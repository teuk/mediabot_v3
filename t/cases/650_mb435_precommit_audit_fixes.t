# t/cases/650_mb435_precommit_audit_fixes.t
# =============================================================================
# mb435 — Independent pre-commit audit after mb421..mb434.
#
# Protects three gaps found in the fresh snapshot:
#   1. truncate_utf8 must accept both raw UTF-8 bytes and decoded character
#      strings (Claude/JSON history) without a Wide character exception;
#   2. Hailo ratio cache must be invalidated after UPDATE as well as INSERT;
#   3. direct achievement scans must compare canonical lowercase channel keys
#      with a folded live IRC channel.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Encode ();

sub _slurp_650 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # --- 1. Execute the real truncate_utf8 source in isolation ------------
    my $helpers = _slurp_650(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my ($truncate_src) = $helpers =~ /(sub truncate_utf8 \{.*?^\})/ms;
    $assert->ok(defined($truncate_src), 'truncate_utf8 source extracted');

    my $loaded = eval "package MB435::Extracted; use strict; use warnings; $truncate_src; 1;";
    $assert->ok($loaded, 'extracted truncate_utf8 compiles') or die $@;

    my $raw = 'abc' . chr(0xC3) . chr(0xA9) . ('x' x 20);
    my $raw_out = MB435::Extracted::truncate_utf8($raw, 4);
    (my $raw_prefix = $raw_out) =~ s/\.\.\.\z//;
    $assert->is($raw_prefix, 'abc', 'raw bytes: incomplete UTF-8 tail removed');

    my $chars = chr(0x00E9) . chr(0x1F60A) . 'abcdef';  # é + smiling face + ASCII
    $assert->ok(utf8::is_utf8($chars), 'character input is upgraded');
    my $char_out = eval { MB435::Extracted::truncate_utf8($chars, 6) };
    $assert->is($@, '', 'character input does not throw Wide character');
    $assert->is($char_out, chr(0x00E9) . chr(0x1F60A) . '...',
        'character input truncates on a codepoint boundary at six wire bytes');
    $assert->ok(utf8::is_utf8($char_out), 'character representation is preserved');

    # --- 2. Hailo UPDATE branch invalidates the cache ----------------------
    my $hailo = _slurp_650(File::Spec->catfile('.', 'Mediabot', 'Hailo.pm'));
    my ($set_body) = $hailo =~ /(sub set_hailo_channel_ratio \{.*?^\})/ms;
    $set_body //= '';
    my $update_at = index($set_body, 'if ($ref_check)');
    my $insert_at = index($set_body, '$sQuery = "INSERT INTO HAILO_CHANNEL');
    my $update_segment = ($update_at >= 0 && $insert_at > $update_at)
        ? substr($set_body, $update_at, $insert_at - $update_at)
        : '';
    $assert->like($update_segment,
        qr/delete \$self->\{_hailo_ratio_cache\}\{lc \$sChannel\}/,
        'existing-row UPDATE invalidates Hailo ratio cache');
    my $delete_count = () = $set_body =~ /delete \$self->\{_hailo_ratio_cache\}\{lc \$sChannel\}/g;
    $assert->is($delete_count, 2, 'both UPDATE and INSERT success paths invalidate cache');

    # --- 3. Achievement aggregate scans fold the live channel -------------
    my $users = _slurp_650(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my $folded_count = () = $users =~ /\$ch eq lc\(\$channel \/\/ ''\)/g;
    $assert->is($folded_count, 2,
        'dashboard and leaderboard compare against folded live channel');
    $assert->unlike($users, qr/next unless defined \$ch && \$ch eq \$channel;/,
        'no raw channel comparison remains in direct achievement scans');

    my %data = (
        "alice\x00#teuk" => { one => 1, two => 2 },
        "bob\x00#other" => { one => 1 },
    );
    my $live_channel = '#TeUk';
    my $count = 0;
    for my $key (keys %data) {
        my (undef, $ch) = split /\x00/, $key, 2;
        next unless defined $ch && $ch eq lc($live_channel // '');
        $count += scalar keys %{ $data{$key} };
    }
    $assert->is($count, 2, 'mixed-case live channel still finds canonical achievements');

    $assert->like($helpers, qr/mb435-B1/, 'mb435-B1 tag present');
    $assert->like($hailo,   qr/mb435-B2/, 'mb435-B2 tag present');
    $assert->like($users,   qr/mb435-B3/, 'mb435-B3 tag present');
};
