# t/cases/12_hotfix_after_claude.t
# =============================================================================
# Regression tests for the post-Claude hardening pass:
#   - quote search SQL-side filtering and LIKE escaping
#   - USER_SEEN lowercase/fault tolerance markers
#   - nick flood lowercase/cleanup
#   - Auth session metrics update helper
#   - WHOIS_VARS Partyline .ban token guard
#   - Log rotation stat throttle/write counter reset
#   - DCC parser ctcp flag behavior
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use Mediabot::DCC qw(parse_ctcp_payload);

sub _slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $quotes_pm    = _slurp(File::Spec->catfile('.', 'Mediabot', 'Quotes.pm'));
    my $helpers_pm   = _slurp(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $auth_pm      = _slurp(File::Spec->catfile('.', 'Mediabot', 'Auth.pm'));
    my $log_pm       = _slurp(File::Spec->catfile('.', 'Mediabot', 'Log.pm'));
    my $partyline_pm = _slurp(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $mediabot_pl  = _slurp(File::Spec->catfile('.', 'mediabot.pl'));

    # -------------------------------------------------------------------------
    # Quotes.pm: quote search must be SQL-side, literal LIKE, not Perl regex.
    # -------------------------------------------------------------------------
    $assert->ok($quotes_pm =~ /LIKE \? ESCAPE/,
        'Quotes.pm: quote search uses LIKE with ESCAPE');

    $assert->ok($quotes_pm =~ /my \@like_words/,
        'Quotes.pm: quote search builds escaped LIKE words');

    $assert->ok($quotes_pm =~ /q\.quotetext LIKE \? ESCAPE '!'/,
        q{Quotes.pm: quote search uses MariaDB-safe ESCAPE '!'});

    $assert->ok($quotes_pm =~ /s\/!\/!!\/g/,
        'Quotes.pm: quote search escapes the LIKE escape character itself');

    $assert->ok($quotes_pm =~ /s\/%\/!%\/g/,
        'Quotes.pm: quote search escapes percent wildcard');

    $assert->ok($quotes_pm =~ /s\/_\/!_\/g/,
        'Quotes.pm: quote search escapes underscore wildcard');

    $assert->ok($quotes_pm !~ /\/\$sQuoteText\/i/,
        'Quotes.pm: quote search no longer uses direct user regex');

    $assert->ok($quotes_pm !~ /ORDER BY RAND\(\)/i,
        'Quotes.pm: quote random no longer uses ORDER BY RAND()');

    # -------------------------------------------------------------------------
    # Helpers.pm: nick flood should be case-insensitive and self-cleaning.
    # -------------------------------------------------------------------------
    $assert->ok($helpers_pm =~ /my \$nick_key = lc\(\$nick\);/,
        'Helpers.pm: checkNickFlood normalizes nick lowercase');

    $assert->ok($helpers_pm =~ /_nick_flood_last_cleanup/,
        'Helpers.pm: checkNickFlood has stale-state cleanup marker');

    # -------------------------------------------------------------------------
    # Auth.pm: metric must be updated after session mutations through helper.
    # -------------------------------------------------------------------------
    $assert->ok($auth_pm =~ /sub _update_auth_session_metric/,
        'Auth.pm: auth session metric helper exists');

    $assert->ok($auth_pm =~ /mediabot_auth_sessions_total/,
        'Auth.pm: mediabot_auth_sessions_total gauge is updated');

    $assert->ok($auth_pm =~ /\$self->\{sessions\}\{lc \$nick\}/,
        'Auth.pm: autologin writes session by lowercase nick');

    $assert->ok($auth_pm =~ /\$self->_update_auth_session_metric\(\);/,
        'Auth.pm: session metric helper is called');

    # -------------------------------------------------------------------------
    # Partyline + mediabot.pl: WHOIS token guard must be real, not comment-only.
    # -------------------------------------------------------------------------
    $assert->ok($partyline_pm =~ /pending_whois_token/,
        'Partyline.pm: .ban stores pending WHOIS token on session');

    $assert->ok($partyline_pm =~ /token\s*=>\s*\$ban_token/,
        'Partyline.pm: .ban stores token in WHOIS_VARS');

    $assert->ok($mediabot_pl =~ /WHOIS token mismatch/,
        'mediabot.pl: partylineBan callback detects WHOIS token mismatch');

    $assert->ok($mediabot_pl =~ /\$whois_token\s+eq\s+\$session_token/,
        'mediabot.pl: partylineBan compares WHOIS token with session token');

    $assert->ok($mediabot_pl =~ /delete \$session->\{pending_whois_token\}/,
        'mediabot.pl: partylineBan clears pending WHOIS token after match');

    # -------------------------------------------------------------------------
    # Log.pm: rotation checks should be throttled and reset after reopen/rotate.
    # -------------------------------------------------------------------------
    $assert->ok($log_pm =~ /_write_count/,
        'Log.pm: write counter exists for rotation throttling');

    $assert->ok($log_pm =~ /\$self->\{_write_count\}\s*=\s*0;/,
        'Log.pm: write counter is reset');

    $assert->ok($log_pm !~ /sub _maybe_rotate \{[\s\S]{0,300}my \$size = -s \$self->\{logfile\};/,
        'Log.pm: _maybe_rotate no longer immediately stats logfile at function start');

    # -------------------------------------------------------------------------
    # mediabot.pl: updateUserSeen should be protected in event handlers.
    # -------------------------------------------------------------------------
    $assert->ok($mediabot_pl =~ /updateUserSeen failed/,
        'mediabot.pl: updateUserSeen failures are logged/protected');

    # -------------------------------------------------------------------------
    # DCC parser: raw CTCP vs stripped payload flags.
    # -------------------------------------------------------------------------
    {
        my $r = parse_ctcp_payload("\x01DCC CHAT chat 1383695523 1024\x01");
        $assert->is($r->{ctcp}, 1,
            'DCC parser: raw CTCP DCC has ctcp flag 1');
    }

    {
        my $r = parse_ctcp_payload("CHAT chat 1383695523 1024");
        $assert->is($r->{ctcp}, 0,
            'DCC parser: stripped DCC has ctcp flag 0');
    }
};
