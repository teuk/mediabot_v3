# t/cases/235_external_claude_persona.t
# =============================================================================
# Verify !ai persona subcommand in claude_ctx and override in claudeAI (I2).
# =============================================================================
use strict; use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
sub _slurp { open my $fh,'<:encoding(UTF-8)',$_[0] or die $!; local $/; <$fh> }
sub _sub { my($s,$n)=@_; my $re=qr/^[ \t]*sub[ \t]+\Q$n\E\b[^{]*\{/m;
    return undef unless $s=~/$re/g; my($st,$p,$d)=($-[0],pos($s),1);
    while($p<length($s)){my $c=substr($s,$p,1);$d++ if $c eq '{';$d-- if $c eq '}';
    return substr($s,$st,$p+1-$st) if $d==0; $p++} undef }
return sub {
    my ($assert) = @_;
    my $src  = _slurp(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));

    # claude_ctx routing
    my $ctx_body = _sub($src, 'claude_ctx');
    $assert->ok(defined $ctx_body, 'claude_ctx body found');
    $assert->like($ctx_body // '', qr/I2.*persona|persona.*I2/i,
        'claude_ctx has I2 persona subcommand');
    $assert->like($ctx_body // '', qr/_claude_persona/,
        'claude_ctx stores persona in _claude_persona');
    $assert->like($ctx_body // '', qr/Persona set/,
        'claude_ctx confirms persona set via botNotice');
    $assert->like($ctx_body // '', qr/delete.*_claude_persona|Persona cleared/,
        'claude_ctx clears persona when called with no args');
    $assert->like($ctx_body // '', qr/400/,
        'claude_ctx caps persona at 400 chars');

    # claudeAI override
    my $ai_body = _sub($src, 'claudeAI');
    $assert->ok(defined $ai_body, 'claudeAI body found');
    $assert->like($ai_body // '', qr/I2.*per-nick persona|persona.*override/i,
        'claudeAI applies per-nick persona override');
    $assert->like($ai_body // '', qr/_claude_persona/,
        'claudeAI reads _claude_persona for override');
    $assert->like($ai_body // '', qr/sys_prompt = \$persona/,
        'claudeAI replaces sys_prompt with persona when set');

    # Help entry
    my $mm = _slurp(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    $assert->like($mm, qr/ai persona/,
        'Mediabot.pm help entry mentions ai persona');
};
