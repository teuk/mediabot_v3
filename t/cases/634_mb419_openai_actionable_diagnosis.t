# t/cases/634_mb419_openai_actionable_diagnosis.t
# =============================================================================
# mb419 — OpenAI failures must tell the operator what to do, and the public
# tellme/chatGPT path must honour the same configurable timeout as diagnostics.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_634 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $claude = _slurp_634(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));
    my $admin  = _slurp_634(File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm'));
    my $sample = _slurp_634('mediabot.sample.conf');

    $assert->like(
        $claude,
        qr/_chatgpt_conf_int\(\s*\$self,\s*'openai\.TIMEOUT',\s*CHATGPT_TIMEOUT,\s*5,\s*60\)/s,
        'public chatGPT reads bounded openai.TIMEOUT'
    );
    $assert->like(
        $claude,
        qr/_make_http\(\s*timeout\s*=>\s*\$chatgpt_timeout,\s*verify_SSL\s*=>\s*1/s,
        'public chatGPT uses configured timeout with verified TLS'
    );
    my ($chatgpt_body) = $claude =~ /sub chatGPT \{(.*?)^sub _chatgpt_wrap \{/ms;
    $assert->ok(defined $chatgpt_body, 'chatGPT body extracted');
    $assert->unlike(
        $chatgpt_body // '',
        qr/_make_http\(timeout => 30\)/,
        'hard-coded 30 second OpenAI timeout removed from chatGPT'
    );

    $assert->like(
        $claude,
        qr/API key accepted, but API credits\/budget are exhausted/,
        'insufficient_quota explicitly confirms accepted key'
    );
    $assert->like(
        $claude,
        qr/replace openai\.API_KEY and reload\/restart Mediabot/,
        '401 tells operator to replace the key'
    );
    $assert->like(
        $claude,
        qr/project\/model\/region permissions \(the key is not necessarily invalid\)/,
        '403 is not misreported as a dead key'
    );

    $assert->like(
        $admin,
        qr/Mediabot::External::Claude::_chatgpt_error_cause\(\$res->\{content\}\)/,
        'Owner test uses the same OpenAI error parser'
    );
    $assert->like(
        $admin,
        qr/OpenAI test: diagnosis=\$diagnosis/,
        'Owner test prints actionable diagnosis'
    );
    $assert->like(
        $admin,
        qr/\$primary_status == 429 && !\$primary_quota/,
        'Owner test does not waste fallback call on exhausted quota'
    );
    $assert->like(
        $admin,
        qr/timeout => \{.*?key\s*=>\s*'openai\.TIMEOUT'.*?min\s*=>\s*5.*?max\s*=>\s*60/s,
        'Owner runtime configuration exposes bounded timeout'
    );

    $assert->like(
        $sample,
        qr/NOT used for insufficient_quota.*billing\/credits/s,
        'sample config explains why a fallback model cannot repair billing quota'
    );
    $assert->like(
        $sample,
        qr/public tellme\/chatGPT calls and Owner diagnostics/,
        'sample config documents shared timeout scope'
    );
};
