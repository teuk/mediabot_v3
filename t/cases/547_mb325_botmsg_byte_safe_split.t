# t/cases/547_mb325_botmsg_byte_safe_split.t
# =============================================================================
# mb325 — Découpage des messages IRC sûr en octets (PRIVMSG / NOTICE).
#
# botPrivmsg() et botNotice() découpaient à 400 *caractères* puis encodaient en
# UTF-8 juste avant l'envoi. 400 caractères accentués (é = 2 octets) ou emojis
# (4 octets) dépassent la limite IRC d'environ 512 octets → la ligne était
# tronquée côté serveur, qui coupait en plein milieu d'une séquence UTF-8.
#
# _split_text_for_irc() (helper partagé) découpe sur des frontières de
# caractères tout en garantissant que chaque chunk tient dans le budget d'octets,
# en respectant le flag utf8 du scalaire (comme do_PRIVMSG/do_NOTICE en aval).
#
# Le test extrait le helper du source et l'exécute en isolation.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use Encode qw(encode);

sub _slurp_547 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_547 {
    my ($src, $name) = @_;
    return undef unless $src =~ /(sub\s+\Q$name\E\s*\{)/;
    my $start = $-[0];
    my $i     = index($src, '{', $start);
    return undef if $i < 0;
    my $depth = 0;
    for (my $p = $i; $p < length($src); $p++) {
        my $c = substr($src, $p, 1);
        $depth++ if $c eq '{';
        $depth-- if $c eq '}';
        return substr($src, $start, $p - $start + 1) if $depth == 0;
    }
    return undef;
}

sub _wire_len {
    my ($s) = @_;
    return utf8::is_utf8($s) ? length(encode('UTF-8', $s)) : length($s);
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_547(
        File::Spec->catfile('.', 'Mediabot', 'Helpers.pm')
    );

    my $sanitize_text = _extract_sub_547($src, '_sanitize_irc_text');
    my $sub_text = _extract_sub_547($src, '_split_text_for_irc');
    $assert->ok(
        defined $sanitize_text && $sanitize_text ne '',
        '_sanitize_irc_text source extracted'
    );
    $assert->ok(
        defined $sub_text && $sub_text ne '',
        '_split_text_for_irc source extrait'
    );

    my $compiled = eval qq{
        package T547;
        use Encode qw(encode);
        $sanitize_text
        $sub_text
        1;
    };
    $assert->ok($compiled, '_split_text_for_irc compiled in isolation');
    return unless $compiled;
    my $split = \&T547::_split_text_for_irc;

    # --- 1. ASCII court : un seul chunk inchangé ---------------------------
    my @c = $split->('hello world', 400);
    $assert->is(scalar(@c), 1, 'ASCII court → 1 chunk');
    $assert->is($c[0], 'hello world', 'ASCII court inchangé');

    # --- 2. ASCII exactement 400 / 401 ------------------------------------
    @c = $split->('a' x 400, 400);
    $assert->is(scalar(@c), 1, '400 octets ASCII → 1 chunk');
    @c = $split->('a' x 401, 400);
    $assert->ok(scalar(@c) >= 2, '401 octets ASCII → découpé');

    # --- 3. Accents (chaîne de caractères utf8) : chunks <= 400 octets -----
    my $accents = "\x{e9}" x 400;          # 400 'é' = 800 octets UTF-8
    utf8::upgrade($accents);               # force le flag utf8 (cas réel décodé)
    @c = $split->($accents, 400);
    my $max_acc = 0;
    for (@c) { my $b = _wire_len($_); $max_acc = $b if $b > $max_acc; }
    $assert->ok($max_acc <= 400, "accents: chaque chunk <= 400 octets (max=$max_acc)");
    $assert->ok(scalar(@c) >= 2, 'accents: message de 800 octets découpé');

    # --- 4. Emojis (4 octets) : chunks <= 400 octets ----------------------
    my $emojis = "\x{1F600}" x 200;        # 200 😀 = 800 octets
    @c = $split->($emojis, 400);
    my $max_emo = 0;
    for (@c) { my $b = _wire_len($_); $max_emo = $b if $b > $max_emo; }
    $assert->ok($max_emo <= 400, "emojis: chaque chunk <= 400 octets (max=$max_emo)");

    # --- 5. Aucune coupe au milieu d'un caractère -------------------------
    # Chaque chunk doit rester une chaîne de caractères valide : son ré-encodage
    # puis re-décodage UTF-8 doit être l'identité (pas de demi-séquence).
    my $clean = 1;
    for my $chunk (@c) {
        my $rt = eval { Encode::decode('UTF-8', encode('UTF-8', $chunk), Encode::FB_CROAK()) };
        $clean = 0 if $@ || !defined($rt) || $rt ne $chunk;
    }
    $assert->ok($clean, 'emojis: aucun chunk ne coupe une séquence UTF-8');

    # --- 6. Contenu préservé (mots ASCII) ---------------------------------
    my $words = join(' ', map { "tok$_" } 1 .. 200);   # > 400 octets
    @c = $split->($words, 400);
    (my $joined = join(' ', @c)) =~ s/\s+/ /g;
    $assert->is($joined, $words, 'contenu des mots préservé après découpage');
    my $max_w = 0;
    for (@c) { my $b = _wire_len($_); $max_w = $b if $b > $max_w; }
    $assert->ok($max_w <= 400, "mots: chaque chunk <= 400 octets (max=$max_w)");

    # --- 7. Helper réellement utilisé par botPrivmsg ET botNotice ---------
    $assert->like(
        $src,
        qr/my\s+\@chunks\s*=\s*_split_text_for_irc\(\$sMsg,\s*400\)/,
        'botPrivmsg utilise _split_text_for_irc'
    );
    $assert->like(
        $src,
        qr/my\s+\@chunks\s*=\s*_split_text_for_irc\(\$text,\s*400\)/,
        'botNotice utilise _split_text_for_irc'
    );
};
