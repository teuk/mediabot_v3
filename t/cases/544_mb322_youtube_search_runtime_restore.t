# t/cases/544_mb322_youtube_search_runtime_restore.t
# =============================================================================
# MB322: production hotfix after the MB320/MB321 forked worker timed out on
# teuk.org. The live command must use the proven synchronous transport while
# retaining MB320 parsers, size caps, formatting and Context reply routing.
# =============================================================================

use strict;
use warnings;
use File::Spec;

sub _slurp_mb322 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_mb322 {
    my ($src, $name) = @_;
    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;
    my ($start, $pos, $depth) = ($-[0], pos($src), 1);
    my ($quote, $escape, $comment);
    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        if ($comment) { $comment = 0 if $ch eq "\n"; $pos++; next; }
        if (defined $quote) {
            if ($escape) { $escape = 0; $pos++; next; }
            if ($ch eq '\\') { $escape = 1; $pos++; next; }
            if ($ch eq $quote) { undef $quote; $pos++; next; }
            $pos++; next;
        }
        if ($ch eq '#') { $comment = 1; $pos++; next; }
        if ($ch eq "'" || $ch eq '"') { $quote = $ch; $pos++; next; }
        $depth++ if $ch eq '{';
        $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_mb322(
        File::Spec->catfile('.', 'Mediabot', 'External', 'YouTube.pm')
    );
    my $command = _extract_mb322($src, 'youtubeSearch_ctx');
    my $sync    = _extract_mb322($src, '_youtube_search_fetch_sync');
    my $format  = _extract_mb322($src, '_youtube_search_format_entry');

    $assert->ok(defined $command, 'YouTube command callback found');
    $assert->ok(defined $sync, 'hardened synchronous transport found');
    $assert->ok(defined $format, 'shared YouTube formatter found');

    $assert->like(
        $command // '',
        qr/MB32[23]: (?:emergency runtime restoration|restore the proven synchronous transport)/,
        'runtime restoration rationale is documented'
    );
    $assert->like(
        $command // '',
        qr/_youtube_search_fetch_sync\(\$api_key,\s*\$query_txt\)/,
        'live command uses the proven transport path'
    );
    $assert->unlike(
        $command // '',
        qr/_youtube_search_fetch_async\(/,
        'broken forked worker is not used by the live command'
    );
    $assert->like(
        $command // '',
        qr/_youtube_search_format_entry\(\$info\)/,
        'MB320 shared formatter is preserved'
    );
    $assert->like(
        $command // '',
        qr/\$ctx->reply\(/,
        'public and private output stays on Context routing'
    );
    $assert->like(
        $sync // '',
        qr/max_size\s*=>\s*256\s*\*\s*1024/,
        'search response size cap is preserved'
    );
    $assert->like(
        $sync // '',
        qr/max_size\s*=>\s*512\s*\*\s*1024/,
        'metadata response size cap is preserved'
    );
    $assert->like(
        $command // '',
        qr/search_exception/,
        'unexpected transport exceptions retain a diagnostic status'
    );
    $assert->like(
        $command // '',
        qr/youtubeSearch_ctx\(\): \$status: \$detail/,
        'runtime errors remain diagnostic in logs'
    );
    $assert->like(
        $src,
        qr/Mediabot::Helpers::logBot\(\s*\$self,\s*\$log_message,\s*\$log_channel,\s*'yt'/s,
        'successful searches keep historical command logging'
    );
    # MB1314: compact search presentation, using real Context reply routing.
    require Mediabot::External::YouTube;
    require Mediabot::Context;
    require Mediabot::IRC::TextBudget;
    {
        package MB1314::Conf;
        sub get { 'OFFLINE_KEY' }
        package MB1314::Bot;
        sub botPrivmsg { push @{$_[0]{wire}}, ['public',$_[1],$_[2]] }
        sub botNotice { push @{$_[0]{wire}}, ['notice',$_[1],$_[2]] }
    }
    my @entries = map {{id=>$_,title=>('Melody ' . chr(0xE9) . chr(0x1F3B5) . ' Nelson ' x 12),channel_title=>'Studio',
        duration=>'PT2M5S',views=>1234}} qw(abcdefgh123 abcdefgh124 abcdefgh125);
    no warnings qw(redefine once);
    my $result;
    local *Mediabot::External::YouTube::_youtube_search_fetch_sync = sub { $result };
    my @audit;
    local *Mediabot::Helpers::logBot = sub { push @audit, [@_[2..$#_]] };
    for my $count (1..3) {
        for my $channel ('#test',undef) {
            @audit=();
            $result = {ok=>1,entries=>[@entries[0..$count-1]]};
            my $bot = bless {conf=>bless({},'MB1314::Conf'),wire=>[]},'MB1314::Bot';
            my $ctx = Mediabot::Context->new(bot=>$bot,nick=>'Reader',channel=>$channel,args=>['Melody','Nelson']);
            Mediabot::External::YouTube::youtubeSearch_ctx($ctx);
            $assert->is(scalar @{$bot->{wire}},1,'search produces one logical result list');
            my $wire = $bot->{wire}[0];
            $assert->is(join('|',@$wire[0,1]),defined($channel)?'public|#test':'notice|Reader','Context preserves public/private routing');
            my $text = join('', map {$_->[2]} @{$bot->{wire}});
            my $badge = "\x0301,00[You\x0300,04Tube\x0301,00]\x0f";
            $assert->is(scalar(() = $text =~ /\Q$badge\E/g),1,'current badge appears exactly once');
            $assert->unlike($text,qr/\b[123]\/[123]\b/,'result ranks are absent');
            $assert->is(scalar(() = $text =~ /\|/g),$count-1,'results have pipe separators');
            my @urls = $text =~ m{https://www\.youtube\.com/watch\?v=([A-Za-z0-9_-]{11})}g;
            $assert->is(join(',',@urls),join(',',map {$_->{id}} @entries[0..$count-1]),'all video links retain their order');
            my @chunks = Mediabot::IRC::TextBudget::_split_text_for_irc($text,400);
            $assert->ok(!(grep {Mediabot::IRC::TextBudget::_irc_wire_bytes($_)>400} @chunks),'existing sender wrapping respects the byte budget');
            my @sent_urls = map { m{https://www\.youtube\.com/watch\?v=([A-Za-z0-9_-]{11})}g } @chunks;
            $assert->is(join(',',@sent_urls),join(',',@urls),'wrapping long Unicode titles preserves every clickable URL');
            $assert->is(scalar @audit,1,'search is audited once');
        }
    }
};
