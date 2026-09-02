# Gemini command wiring, opt-in migration, configuration and documentation.

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

sub _slurp_1030 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/; return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $sample = _slurp_1030('mediabot.sample.conf');
    my ($gemini) = $sample =~ /^\[gemini\]\s*\n(.*?)(?=^\[[^\]]+\]\s*$|\z)/ms;
    $assert->ok(defined($gemini), 'sample config has a Gemini section');
    $assert->like($gemini // '', qr/^API_KEY=$/m,
        'Gemini API key is empty by default');
    $assert->unlike($gemini // '', qr/^API_KEY=\S+/m,
        'sample config contains no Gemini credential');
    $assert->like($gemini // '', qr/^MODEL=gemini-3\.8-flash$/m,
        'sample uses the current stable Gemini Flash model');
    $assert->like($gemini // '', qr/^THINKING_LEVEL=LOW$/m,
        'sample bounds Gemini thinking for short IRC output');
    $assert->like($gemini // '', qr/^MAX_TOKENS=1024$/m,
        'sample reserves visible output room beyond Gemini thinking tokens');
    $assert->like($gemini // '', qr/chanset #channel \+Gemini/,
        'sample documents explicit channel opt-in');

    my $external = _slurp_1030('Mediabot/External.pm');
    $assert->like($external, qr/require Mediabot::External::Gemini/,
        'External facade loads Gemini command module');
    $assert->like($external, qr/our \@EXPORT.*?gemini_ctx/s,
        'External facade exports Gemini context wrapper');

    my $mediabot = _slurp_1030('Mediabot/Mediabot.pm');
    $assert->like($mediabot, qr/gemini\s*=>\s*sub\s*\{\s*gemini_ctx\(\$ctx\)/,
        'public dispatcher maps gemini command');
    $assert->like($mediabot, qr/gemini\|gemini <prompt>\|public\|/,
        'public help documents gemini syntax');

    my $sql = _slurp_1030('install/mediabot.sql');
    $assert->like($sql, qr/\(31,\s*'Gemini'\)/,
        'fresh schema registers Gemini chanset with a unique id');

    my $migration = _slurp_1030('install/migrations/20260902_gemini_chanset.sql');
    $assert->like($migration, qr/INSERT INTO CHANSET_LIST.*?SELECT 'Gemini'.*?NOT EXISTS/s,
        'upgrade migration registers Gemini idempotently');
    $assert->unlike($migration, qr/INSERT\s+(?:IGNORE\s+)?INTO\s+CHANNEL_SET/i,
        'migration enables Gemini on no channel');

    for my $doc ('docs/DB_MIGRATIONS.md', 'install/migrations/README.md') {
        $assert->like(_slurp_1030($doc), qr/20260902_gemini_chanset\.sql/,
            "$doc lists Gemini migration");
    }

    my $change = _slurp_1030('CHANGELOG.md');
    $assert->like($change, qr/^### mb721\b[^\n]*Gemini/im,
        'changelog identifies Gemini integration as MB721');

    my $roadmap = _slurp_1030('docs/ROADMAP_3.5.md');
    $assert->like($roadmap,
        qr/^\| MB721 \| Complete on development pilot \|[^\n]*Gemini[^\n]*opt-in IRC pilot passed/m,
        'roadmap records the qualified MB721 development pilot');
    $assert->like($roadmap,
        qr/^\| MB722 \| P0 \| Supported instances converge/m,
        'post-Gemini convergence keeps a distinct future work number');
    $assert->like($roadmap, qr/^\| MB727 \| Final \|/m,
        'final release gate is renumbered without collision');

    my $hailo = _slurp_1030('Mediabot/Hailo.pm');
    $assert->like($hailo, qr/auto\|anthropic\|openai\|gemini/,
        'Hailo provider selection accepts Gemini explicitly');

    my $metrics = _slurp_1030('Mediabot/Metrics.pm');
    for my $name (qw(requests errors ratelimit)) {
        $assert->like($metrics, qr/mediabot_gemini_${name}_total/,
            "Gemini $name metric is declared");
    }
};
