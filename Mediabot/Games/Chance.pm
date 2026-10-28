package Mediabot::Games::Chance;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Mediabot::Helpers ();

our @EXPORT_OK = qw(
    mb8ball_ctx
    mbSlap_ctx
    mbRoll_ctx
    mbFlip_ctx
    mbChoose_ctx
);

# Resolve historical transport hooks at call time: existing callers and test
# integrations may replace them after either module has been loaded.
sub botPrivmsg { goto &Mediabot::UserCommands::botPrivmsg }
sub botNotice  { goto &Mediabot::UserCommands::botNotice }
sub logBot     { goto &Mediabot::UserCommands::logBot }
sub botAction  { goto &Mediabot::UserCommands::botAction }

# ---------------------------------------------------------------------------
# mb8ball_ctx --- !8ball <question>
# ---------------------------------------------------------------------------
sub mb8ball_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $question = join(' ', @args);
    $question =~ s/^\s+|\s+$//g;

    unless ($question ne '') {
        botNotice($self, $nick, "Syntax: 8ball <question>");
        return;
    }

    # J3: French answers if main.LANG = fr
    # mb563-B1: per-channel override via chansets +LangFR/+LangES
    # (Helpers::channel_lang); PM and unflagged channels keep main.LANG.
    # mb562-B1: FR/ES pools were double-encoded (accents shipped broken on
    # IRC); re-encoded once. Guard 753 forbids mojibake file-wide.
    my $lang_8b = Mediabot::Helpers::channel_lang($self, $channel);

    my @answers = (
        'It is certain.',
        'It is decidedly so.',
        'Without a doubt.',
        'Yes, definitely.',
        'You may rely on it.',
        'As I see it, yes.',
        'Most likely.',
        'Outlook good.',
        'Yes.',
        'Signs point to yes.',
        'Reply hazy, try again.',
        'Ask again later.',
        'Better not tell you now.',
        'Cannot predict now.',
        'Concentrate and ask again.',
        "Don't count on it.",
        'My reply is no.',
        'My sources say no.',
        'Outlook not so good.',
        'Very doubtful.',
    );
    my @answers_fr = (
        'C\'est certain.',
        'C\'est absolument ça.',
        'Sans aucun doute.',
        'Oui, définitivement.',
        'Tu peux compter dessus.',
        'Comme je le vois, oui.',
        'Très probablement.',
        'Les perspectives sont bonnes.',
        'Oui.',
        'Les signes indiquent que oui.',
        'Flou, essaie encore.',
        'Demande plus tard.',
        'Mieux vaut ne pas te le dire maintenant.',
        'Je ne peux pas prédire ça.',
        'Concentre-toi et redemande.',
        'N\'y compte pas.',
        'Ma réponse est non.',
        'Mes sources disent non.',
        'Les perspectives ne sont pas bonnes.',
        'Très douteux.',
    );
    @answers = @answers_fr if $lang_8b eq 'fr';

    # L2: Spanish answers if main.LANG = es
    my @answers_es = (
        'Definitivamente sí.',
        'Por supuesto.',
        'Sin ninguna duda.',
        'Sí, definitivamente.',
        'Puedes contar con ello.',
        'Las perspectivas son buenas.',
        'Muy probablemente.',
        'Sí.',
        'Los indicios apuntan que sí.',
        'Como yo lo veo, sí.',
        'La respuesta es incierta, intenta de nuevo.',
        'Pregunta más tarde.',
        'Mejor no responderte ahora.',
        'No puedo predecirlo.',
        'Concéntrate y pregunta de nuevo.',
        'No cuentes con ello.',
        'Mi respuesta es no.',
        'Mis fuentes dicen que no.',
        'Las perspectivas no son buenas.',
        'Muy dudoso.',
    );
    @answers = @answers_es if $lang_8b eq 'es';


    my $answer = $answers[int(rand(scalar @answers))];
    botPrivmsg($self, $channel, "\x038\x02[8ball]\x0f $nick: $answer");
    logBot($self, $ctx->message, $channel, '8ball', $question);
    return 1;
}

# ---------------------------------------------------------------------------
# mbSlap_ctx --- !slap [nick]
# Classic IRC slap via CTCP ACTION.
# ---------------------------------------------------------------------------
sub mbSlap_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $target = $args[0] // $nick;
    $target = $nick if $target eq '';

    my @weapons = (
        'a large trout',
        'a wet noodle',
        'a rubber chicken',
        'a copy of the Camel Book',
        'a frozen pizza',
        'a soggy newspaper',
        'a 10kg bag of CPAN modules',
        'a Perl regex manual',
    );
    my $weapon = $weapons[int(rand(scalar @weapons))];

    botAction($self, $channel, "slaps $target with $weapon");
    logBot($self, $ctx->message, $channel, 'slap', $target);
    return 1;
}

# ---------------------------------------------------------------------------
# mbRoll_ctx --- !roll [NdN]
# Roll dice. Defaults to 1d6. Supports NdN format.
# ---------------------------------------------------------------------------
sub mbRoll_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # mb85-IMP2: !roll history — show last 5 rolls on this channel
    if (@args && lc($args[0]) eq 'history') {
        my $hist = $self->{_roll_history}{$channel} // [];
        unless (@$hist) {
            botPrivmsg($self, $channel, "$nick: no roll history on $channel."); return 1;
        }
        botPrivmsg($self, $channel, 'Last rolls: ' . join('  |  ', reverse @$hist));
        return 1;
    }

    my ($num, $sides) = (1, 6);
    my $modifier = 0;   # mb85-IMP2: +N / -N bonus
    my $adv_mode = '';  # 'adv', 'dis', or ''

    if (@args && $args[0] =~ /^(\d+)d(\d+)$/i) {
        ($num, $sides) = ($1, $2);
        $num   = 1   if $num   < 1;  $num   = 20  if $num   > 20;
        $sides = 2   if $sides < 2;  $sides = 100 if $sides > 100;
        shift @args;
    } elsif (@args && $args[0] =~ /^\d+$/) {
        $sides = int($args[0]);
        $sides = 2 if $sides < 2; $sides = 100 if $sides > 100;
        shift @args;
    }

    # Consume a dice token only when present; otherwise options start at zero
    # and apply to the default 1d6 roll.
    for my $extra (@args) {
        if ($extra =~ /^([+-]\d+)$/) {
            $modifier = int($1);
            $modifier =  100 if $modifier >  100;
            $modifier = -100 if $modifier < -100;
        } elsif ($extra =~ /^adv(?:antage)?$/i)    { $adv_mode = 'adv'; }
        elsif  ($extra =~ /^dis(?:advantage)?$/i)  { $adv_mode = 'dis'; }
    }

    my @results = map { int(rand($sides)) + 1 } 1..$num;
    my $label   = "${num}d${sides}";
    my $out;

    if ($adv_mode && $num == 1) {
        # adv/dis: roll twice, keep highest/lowest
        my $r2   = int(rand($sides)) + 1;
        my $kept = $adv_mode eq 'adv'
            ? ($results[0] >= $r2 ? $results[0] : $r2)
            : ($results[0] <= $r2 ? $results[0] : $r2);
        my $drop = $adv_mode eq 'adv'
            ? ($results[0] < $r2  ? $results[0] : $r2)
            : ($results[0] > $r2  ? $results[0] : $r2);
        my $total = $kept + $modifier;
        my $mod_str = $modifier ? sprintf(' %+d = %d', $modifier, $total) : '';
        # mb425-R1: le dé écarté était affiché "~~8~~" (barré Markdown/Discord),
        # rendu en tildes littéraux sur IRC. On utilise le vrai code de barré
        # IRC \x1e (rendu par mIRC/HexChat/WeeChat/Kiwi) + \x0f de reset, en
        # gardant le nombre lisible même sur un client qui l'ignore.
        my $drop_str = "\x1e$drop\x0f";
        $out = sprintf('%s rolled %s (%s): [%d, %s]%s  → %d',
            $nick, $label, $adv_mode, $kept, $drop_str, $mod_str, $total);
    } elsif ($num == 1) {
        my $total = $results[0] + $modifier;
        my $mod_str = $modifier ? sprintf(' %+d = %d', $modifier, $total) : '';
        $out = "$nick rolled $label: $results[0]$mod_str";
    } else {
        my $sum = 0; $sum += $_ for @results;
        my $total = $sum + $modifier;
        my $mod_str = $modifier ? sprintf(' %+d = %d', $modifier, $total) : " = $sum";
        $out = sprintf('%s rolled %s: [%s]%s',
            $nick, $label, join(', ', @results), $mod_str);
    }

    # mb85-IMP2: keep rolling history (last 5 per channel)
    my $rh = $self->{_roll_history}{$channel} //= [];
    push @$rh, $out;
    splice @$rh, 0, @$rh - 5 if @$rh > 5;

    botPrivmsg($self, $channel, $out);
    logBot($self, $ctx->message, $channel, 'roll', $label);
    return 1;
}

# ---------------------------------------------------------------------------
# mbFlip_ctx --- !flip
# Flip a coin.
# ---------------------------------------------------------------------------
sub mbFlip_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # mb85-IMP3: !flip stats — show heads/tails counts on this channel
    if (@args && lc($args[0]) eq 'stats') {
        my $fs = $self->{_flip_stats}{$channel} // { h => 0, t => 0 };
        my $total = $fs->{h} + $fs->{t};
        unless ($total) {
            botPrivmsg($self, $channel, "$nick: no flips yet on $channel."); return 1;
        }
        botPrivmsg($self, $channel, sprintf(
            '%s flip stats on %s: %d Heads (%.0f%%)  %d Tails (%.0f%%)  — %d total',
            $nick, $channel,
            $fs->{h}, 100*$fs->{h}/$total,
            $fs->{t}, 100*$fs->{t}/$total,
            $total));
        return 1;
    }

    # mb85-IMP3: !flip N — multi-flip (max 10)
    my $n = 1;
    if (@args && $args[0] =~ /^(\d+)$/) {
        $n = int($1); $n = 1 if $n < 1; $n = 10 if $n > 10;
    }

    my @results;
    my $fs = $self->{_flip_stats}{$channel} //= { h => 0, t => 0 };
    for (1..$n) {
        my $r = rand() < 0.5 ? 'H' : 'T';
        push @results, $r;
        $r eq 'H' ? $fs->{h}++ : $fs->{t}++;
    }

    if ($n == 1) {
        my $word = $results[0] eq 'H' ? 'Heads!' : 'Tails!';
        botPrivmsg($self, $channel, "$nick flipped a coin: $word");
    } else {
        my $heads = scalar grep { $_ eq 'H' } @results;
        my $tails = $n - $heads;
        my $seq   = join('', @results);
        $seq      =~ s/H/H/g; $seq =~ s/T/T/g;
        botPrivmsg($self, $channel, sprintf(
            '%s flipped %d coins: %s  (%d H, %d T)',
            $nick, $n, $seq, $heads, $tails));
    }
    logBot($self, $ctx->message, $channel, 'flip', join('', @results));
    return 1;
}

# ---------------------------------------------------------------------------
# mbChoose_ctx --- !choose <a> | <b> | <c>
# ---------------------------------------------------------------------------
sub mbChoose_ctx {
    my ($ctx) = @_;
    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $raw = join(' ', @args);
    # Y8: !choose history — show last 5 choices
    if (@args && lc($args[0]) eq 'history') {
        my $hist = $self->{_choose_history}{$channel} // [];
        unless (@$hist) {
            botPrivmsg($self, $channel, "$nick: no choice history on $channel."); return 1;
        }
        botPrivmsg($self, $channel, 'Last choices: ' . join(' | ', reverse @$hist));
        return 1;
    }

    # X4: !choose last — recall the last choice made on this channel
    if (@args && lc($args[0]) eq 'last') {
        my $last = $self->{_choose_last}{$channel};
        # Zero is a valid option label; only undef means no prior choice.
        if (defined $last) {
            botPrivmsg($self, $channel, "$nick: last choice was: $last");
        } else {
            botPrivmsg($self, $channel, "$nick: no previous choice on this channel.");
        }
        return 1;
    }

    # J2: accept both | and ' ou ' (French) as separator
    my $sep = $raw =~ /\|/ ? '\|' : '\s+ou\s+';
    my @raw_opts = map { my $o = $_; $o =~ s/^\s+|\s+$//g; $o } split /$sep/, $raw;
    @raw_opts = grep { $_ ne '' } @raw_opts;
    # DD8: deduplicate options (case-insensitive, preserve first occurrence)
    {
        my %seen;
        my @deduped = grep { !$seen{lc $_}++ } @raw_opts;
        if (scalar @deduped < scalar @raw_opts) {
            my $removed = scalar(@raw_opts) - scalar(@deduped);
            botNotice($self, $nick, "Note: $removed duplicate option(s) removed.");
        }
        @raw_opts = @deduped;
    }
    # U5: weighted choice — 'pizza:3' means pizza appears 3x in pool
    my @opts;
    for my $opt (@raw_opts) {
        if ($opt =~ /^(.+?):(\d+)$/ && $2 >= 1 && $2 <= 20) {
            push @opts, ($1) x $2;
        } else {
            push @opts, $opt;
        }
    }
    # B-69-1/fix: guard against empty pool after dedup+weight
    unless (@opts) {
        botNotice($self, $nick, 'No valid options remain after deduplication.');
        return 1;
    }
    # BX-5/fix: better message when only 1 option remains
    # Weights repeat pool entries; require distinct result labels, not slots.
    my %labels = map { lc($_) => 1 } @opts;
    unless (keys(%labels) >= 2) {
        my $msg = keys(%labels) == 1
            ? "Only one option left after deduplication — nothing to choose from."
            : 'Syntax: choose <a> | <b>  or  choose <a> ou <b>  (at least 2 options).';
        botNotice($self, $nick, $msg);
        return;
    }
    my $choice = $opts[int(rand(scalar @opts))];
    $self->{_choose_last}{$channel} = $choice;  # X4: remember last choice
    # Y8: keep rolling history of 5 choices
    my $ch = $self->{_choose_history}{$channel} //= [];
    push @$ch, $choice;
    splice @$ch, 0, @$ch - 5 if @$ch > 5;
    # V3: show number of options for context
    my $n_opts = scalar @opts;
    botPrivmsg($self, $channel,
        "$nick: I choose... $choice!" . ($n_opts > 2 ? " (1 of $n_opts options)" : ""));
    logBot($self, $ctx->message, $channel, 'choose', $choice);  # Q1
    return 1;
}

1;
