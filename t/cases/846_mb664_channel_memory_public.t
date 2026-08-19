# t/cases/846_mb664_channel_memory_public.t
# =============================================================================
# mb664 step 2 — public Channel Memory wiring.
# =============================================================================
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_846 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $uc = _slurp_846(File::Spec->catfile('.', 'Mediabot', 'SocialHistory.pm'));
    my $mb = _slurp_846(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));

    $assert->like(
        $uc, qr/\bmbMemory_ctx\b/,
        'mb664-846: mbMemory_ctx is present/exported'
    );

    my ($fn) = $uc =~ /(sub mbMemory_ctx \{.*?\n\})(?=\n+(?:sub |1;))/s;
    $fn //= '';

    $assert->like(
        $fn,
        qr/chanset_enabled\(\$self,\s*\$channel,\s*'OnThisDay',\s*default\s*=>\s*1\)/s,
        'mb664-846: memory reuses +OnThisDay gate'
    );
    $assert->like(
        $fn, qr/_memory_lines\(/,
        'mb664-846: public command calls tested memory engine'
    );
    $assert->like(
        $fn, qr/botNotice\(\$self,\s*\$nick,\s*\$_\)\s+for\s+\@lines/,
        'mb664-846: async worker emits direct NOTICE intents for replay'
    );
    $assert->unlike(
        $fn, qr/^\s*queueBotNotices\(/m,
        'mb664-846: async command does not schedule child-loop NOTICE timers'
    );
    $assert->like(
        $fn, qr/older than 30 days/,
        'mb664-846: empty-result message reflects 30-day exclusion'
    );

    $assert->like(
        $mb,
        qr/memory\s*=>\s*sub\s*\{\s*Mediabot::CommandAsync::run_ctx_async\(\$ctx->bot,\s*\$ctx,\s*'memory',\s*sub\s*\{\s*mbMemory_ctx\(\$ctx\)\s*\}\s*\)\s*\}/s,
        'mb664-846: memory dispatch uses CommandAsync'
    );
    $assert->like(
        $mb,
        qr/^memory\|memory\|public\|Take a bounded random trip into this channel's history/m,
        'mb664-846: memory is documented in public help'
    );
    $assert->like(
        $mb,
        qr/memory\s*=>\s*'social'/,
        'mb664-846: memory belongs to social help category'
    );
    $assert->like(
        $mb,
        qr/\+OnThisDay\s+: allow onthisday\/otd and memory channel-history features/,
        'mb664-846: existing chanset documentation includes memory'
    );
    $assert->unlike(
        $mb,
        qr/\+Memory\b/,
        'mb664-846: MB664 does not invent a new chanset'
    );
};
