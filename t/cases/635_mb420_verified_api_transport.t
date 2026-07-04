# t/cases/635_mb420_verified_api_transport.t
# =============================================================================
# mb420 — Credential-bearing external API calls must verify TLS, OpenAI Owner
# commands must share one diagnosis path, and API keys must never appear in logs.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_635 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $claude = _slurp_635(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));
    my $admin  = _slurp_635(File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm'));
    my $yt     = _slurp_635(File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm'));
    my $sample = _slurp_635('mediabot.sample.conf');

    my ($chatgpt) = $claude =~ /sub chatGPT \{(.*?)^sub _chatgpt_wrap \{/ms;
    $assert->ok(defined $chatgpt, 'chatGPT body extracted');
    $assert->like(
        $chatgpt // '',
        qr/_make_http\(\s*timeout\s*=>\s*\$chatgpt_timeout,\s*verify_SSL\s*=>\s*1/s,
        'public OpenAI request verifies TLS'
    );

    my ($tmdb) = $claude =~ /sub get_tmdb_info \{(.*?)^sub claude_ctx \{/ms;
    $assert->like($tmdb // '', qr/_make_http\(timeout => 10, verify_SSL => 1\)/,
        'TMDB API-key request verifies TLS');

    my $verified_claude_calls = () = $claude =~ /_make_http\([^;]*?verify_SSL\s*=>\s*1[^;]*?\)/sg;
    $assert->ok($verified_claude_calls >= 4,
        'OpenAI, TMDB and Anthropic credentialed clients verify TLS');

    my ($run_test) = $admin =~ /sub _openai_run_test \{(.*?)^sub _openai_profile_spec \{/ms;
    $assert->like($run_test // '', qr/verify_SSL\s*=>\s*1/,
        'OpenAI Owner diagnostic verifies TLS');

    my ($models) = $admin =~ /sub _openai_notice_models \{(.*?)^sub openai_ctx \{/ms;
    $assert->like($models // '', qr/verify_SSL\s*=>\s*1/,
        'OpenAI model listing verifies TLS');
    $assert->like($models // '', qr/_chatgpt_error_cause\(\$res->\{content\}\)/,
        'OpenAI model listing uses shared error parser');
    $assert->like($models // '', qr/OpenAI models: diagnosis=\$diagnosis/,
        'OpenAI model listing prints actionable diagnosis');

    my $verified_youtube_calls = () = $yt =~ /_make_http\([^;]*?verify_SSL\s*=>\s*1[^;]*?\)/sg;
    $assert->ok($verified_youtube_calls >= 6,
        'YouTube and Fortnite credentialed clients verify TLS');
    $assert->unlike($yt, qr/log\([^\n]*\$yt_url/,
        'YouTube API key-bearing URL is never written to logs');

    $assert->like($claude, qr/\[\\x00-\\x1F\\x7F\]\+\/ \/g/,
        'provider error fields strip control bytes before logs and notices');

    $assert->like($admin, qr/openai status\|config\|help\|defaults\|profiles\|test\|diagnose\|models/,
        'Owner help documents diagnose alias');
    $assert->like($sample, qr/test\/diagnose also tries FALLBACK_MODEL.*transient 429/s,
        'sample config documents transient 429 fallback');
};
