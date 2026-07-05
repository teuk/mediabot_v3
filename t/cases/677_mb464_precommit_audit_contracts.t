# t/cases/677_mb464_precommit_audit_contracts.t
# =============================================================================
# mb464 — pre-commit audit contracts.
#
# Executes the REAL bodies of the two pure helpers changed by the audit:
#   - _karma_current_score: channel-aware + deterministic equal-ts tie-break
#   - _extract_youtube_id: only genuine YouTube hosts/paths
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

my $SEQ_677 = 0;
sub _load_real_sub_677 {
    my ($relpath, $name) = @_;
    my $path = File::Spec->catfile('.', split(m{/}, $relpath));
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/; my $src = <$fh>;
    my ($body) = $src =~ /(^sub \Q$name\E \{.*?^\}\n)/ms;
    die "sub $name not found in $relpath" unless $body;
    my $pkg = 'T_mb464_' . (++$SEQ_677);
    my $code = eval "package $pkg; use strict; use warnings;\n$body\n\\&${pkg}::${name};";
    die "eval of $name failed: $@" if $@ || !$code;
    return $code;
}

return sub {
    my ($assert) = @_;

    my $score = _load_real_sub_677('Mediabot/UserCommands.pm', '_karma_current_score');
    my $bot = {
        _karma_log => {
            '#Alpha' => [
                { ts => 100, nick => 'Bob', score => 2 },
                { ts => 200, nick => 'bob', score => 4 },
                { ts => 200, nick => 'BOB', score => 5 }, # later in same channel
            ],
            '#beta' => [
                { ts => 300, nick => 'bob', score => 9 },
            ],
        },
    };
    $assert->is($score->($bot, 'bob', '#alpha'), 5,
        'channel scope: same-channel latest entry wins, including equal-ts array order');
    $assert->is($score->($bot, 'bob', '#BETA'), 9,
        'channel scope is case-insensitive');
    $assert->is($score->($bot, 'bob', undef), 9,
        'global caller sees latest entry across channels');
    $assert->ok(!defined $score->($bot, 'ghost', '#alpha'),
        'unknown nick returns undef');
    $assert->ok(!defined $score->($bot, 'bob', '#missing'),
        'unknown channel returns undef');

    my $tie_bot = {
        _karma_log => {
            '#a' => [ { ts => 500, nick => 'kai', score => 1 } ],
            '#b' => [ { ts => 500, nick => 'kai', score => 2 } ],
        },
    };
    $assert->is($score->($tie_bot, 'kai', undef), 2,
        'equal timestamp across channels uses stable lexical tie-break');

    my $yt = _load_real_sub_677('Mediabot/Radio/Request.pm', '_extract_youtube_id');
    $assert->is($yt->('https://youtube.com/watch?list=PL1&v=dQw4w9WgXcQ'), 'dQw4w9WgXcQ',
        'real watch URL extracts ID');
    $assert->is($yt->('https://youtu.be/dQw4w9WgXcQ?t=3'), 'dQw4w9WgXcQ',
        'real youtu.be URL extracts ID');
    $assert->is($yt->('https://m.youtube.com/shorts/dQw4w9WgXcQ'), 'dQw4w9WgXcQ',
        'real shorts URL extracts ID');
    $assert->is($yt->('dQw4w9WgXcQ'), 'dQw4w9WgXcQ',
        'bare ID remains supported');

    for my $bad (
        'https://example.org/?v=dQw4w9WgXcQ',
        'https://notyoutube.com/watch?v=dQw4w9WgXcQ',
        'https://notyoutu.be/dQw4w9WgXcQ',
        'https://example.org/shorts/dQw4w9WgXcQ',
    ) {
        $assert->ok(!defined $yt->($bad), "non-YouTube URL rejected: $bad");
    }
};
